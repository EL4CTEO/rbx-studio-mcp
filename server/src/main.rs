//! rbx-studio-mcp: an MCP server that drives Roblox Studio through a plugin.

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

mod apidump;
mod bridge;
mod cloud;
mod doctor;
mod errors;
mod format;
mod mcp;
mod png;
mod protocol;
mod sync;
mod tool;
mod tools;

use bridge::StudioBridge;
use protocol::DEFAULT_PORT;
use std::sync::Arc;
use std::time::Duration;

fn parse_port(args: &[String]) -> Result<u16, String> {
    let flag = args.iter().position(|a| a == "--port");
    let raw = match flag {
        Some(i) => match args.get(i + 1).filter(|v| !v.is_empty()) {
            Some(v) => Some(v.clone()),
            None => return Err("Missing value for --port".into()),
        },
        None => std::env::var("ROBLOX_STUDIO_MCP_PORT").ok().filter(|v| !v.is_empty()),
    };
    match raw {
        None => Ok(DEFAULT_PORT),
        Some(v) => v
            .parse::<u16>()
            .ok()
            .filter(|p| *p >= 1 && v.bytes().all(|b| b.is_ascii_digit()))
            .ok_or_else(|| format!("Invalid port: {v}")),
    }
}

/// Whether the process that launched us still exists.
fn parent_alive(pid: u32) -> bool {
    #[cfg(windows)]
    {
        use windows_sys::Win32::Foundation::{CloseHandle, STILL_ACTIVE};
        use windows_sys::Win32::System::Threading::{GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION};
        // SAFETY: plain Win32 calls on a handle we own and close.
        unsafe {
            let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if handle.is_null() {
                return false;
            }
            let mut code = 0u32;
            let ok = GetExitCodeProcess(handle, &mut code);
            CloseHandle(handle);
            ok != 0 && code == STILL_ACTIVE as u32
        }
    }
    #[cfg(unix)]
    {
        // SAFETY: signal 0 only tests for existence; reparenting to init means gone.
        unsafe { libc::getppid() as u32 == pid && libc::kill(pid as i32, 0) == 0 }
    }
}

fn parent_pid() -> Option<u32> {
    #[cfg(windows)]
    {
        use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
        use windows_sys::Win32::System::Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
        };
        let me = std::process::id();
        // SAFETY: a process snapshot walked and closed in this scope.
        unsafe {
            let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if snap == INVALID_HANDLE_VALUE {
                return None;
            }
            let mut entry: PROCESSENTRY32W = std::mem::zeroed();
            entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
            let mut found = None;
            if Process32FirstW(snap, &mut entry) != 0 {
                loop {
                    if entry.th32ProcessID == me {
                        found = Some(entry.th32ParentProcessID);
                        break;
                    }
                    if Process32NextW(snap, &mut entry) == 0 {
                        break;
                    }
                }
            }
            CloseHandle(snap);
            found
        }
    }
    #[cfg(unix)]
    {
        // SAFETY: getppid cannot fail.
        Some(unsafe { libc::getppid() } as u32)
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!("rbx-studio-mcp {}", protocol::VERSION);
        return;
    }
    if args.iter().any(|a| a == "--install-plugin") {
        match doctor::install_plugin() {
            Ok(path) => eprintln!("Studio plugin installed at {}. Open Studio and look for the Studio MCP button.", path.display()),
            Err(e) => {
                eprintln!("Could not install the plugin: {e}");
                std::process::exit(1);
            }
        }
        return;
    }
    let port = match parse_port(&args) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("roblox-studio-mcp failed to start: {e}");
            std::process::exit(1);
        }
    };

    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().expect("tokio runtime");

    if args.iter().any(|a| a == "doctor" || a == "--doctor") {
        let code = runtime.block_on(doctor::run(port));
        std::process::exit(code);
    }

    let code = runtime.block_on(async move {
        let bridge = match StudioBridge::start(port).await {
            Ok(b) => b,
            Err(e) => {
                eprintln!("roblox-studio-mcp failed to start: {e}");
                return 1;
            }
        };
        serve(bridge).await;
        0
    });
    // Background tasks (streams, timers) die with the runtime.
    runtime.shutdown_timeout(Duration::from_millis(200));
    std::process::exit(code);
}

async fn serve(bridge: Arc<StudioBridge>) {
    let tools = tools::all();

    // The parent dying without closing our stdin would otherwise strand the port.
    let parent = parent_pid().filter(|p| *p > 0);
    let orphaned = async move {
        let Some(parent) = parent else { return std::future::pending::<()>().await };
        loop {
            tokio::time::sleep(Duration::from_secs(60)).await;
            if !parent_alive(parent) {
                return;
            }
        }
    };

    let interrupted = async {
        #[cfg(unix)]
        {
            let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).expect("signal");
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {},
                _ = term.recv() => {},
            }
        }
        #[cfg(not(unix))]
        {
            let _ = tokio::signal::ctrl_c().await;
        }
    };

    tokio::select! {
        _ = mcp::serve(bridge.clone(), tools) => {},
        _ = orphaned => {},
        _ = interrupted => {},
    }

    // Before the bridge closes, so the plugin hears the tracking stop.
    sync::stop_all_watches(&bridge).await;
    let _ = tokio::time::timeout(Duration::from_secs(3), bridge.shutdown()).await;
    bridge::harness::cleanup();
}
