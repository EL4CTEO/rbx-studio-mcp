//! Builds `plugin/src` into the StudioMCP.rbxmx this binary embeds.
//!
//! The same rules as scripts/build-plugin.mjs (Rojo naming, CDATA sources,
//! Config stamping). The build id must stay byte-identical to that script's.

use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

fn main() {
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let root = manifest.parent().unwrap().to_path_buf();
    let src = root.join("plugin").join("src");
    println!("cargo:rerun-if-changed={}", src.display());
    println!("cargo:rerun-if-changed={}", root.join("package.json").display());

    let version = package_version(&root);
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    embed_libmp(&root, &out);

    if !src.is_dir() {
        // A crate built outside the repository still compiles; it just has no
        // plugin to install and reports its build id as unknown.
        fs::write(out.join("StudioMCP.rbxmx"), "").unwrap();
        fs::write(out.join("plugin-build-id.txt"), "unknown").unwrap();
        println!("cargo:rustc-env=RBX_PACKAGE_VERSION={version}");
        return;
    }

    let mut files = Vec::new();
    collect(&src, &src, &mut files);
    files.sort_by(|a, b| a.0.cmp(&b.0));
    let mut hash = Sha256::new();
    for (name, path) in &files {
        println!("cargo:rerun-if-changed={}", path.display());
        hash.update(name.as_bytes());
        hash.update(b"\n");
        hash.update(read(path).replace("\r\n", "\n").as_bytes());
        hash.update(b"\n");
    }
    let stamp: String = hash.finalize().iter().map(|b| format!("{b:02x}")).collect::<String>()[..12].to_string();

    let tree = build_tree(&src, "StudioMCP", &stamp, &version);
    let mut referent = 0usize;
    let mut doc = String::new();
    doc.push_str("<roblox xmlns:xmime=\"http://www.w3.org/2005/05/xmlmime\"\n");
    doc.push_str("  xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"\n");
    doc.push_str("  xsi:noNamespaceSchemaLocation=\"http://www.roblox.com/roblox.xsd\" version=\"4\">\n");
    render(&tree, 1, &mut referent, &mut doc);
    doc.push_str("\n</roblox>\n");

    fs::write(out.join("StudioMCP.rbxmx"), doc).unwrap();
    fs::write(out.join("plugin-build-id.txt"), &stamp).unwrap();
    println!("cargo:rustc-env=RBX_PACKAGE_VERSION={version}");
}

/// LibMP is 3.3 MB of Luau; stored deflated, inflated on first request.
fn embed_libmp(root: &Path, out: &Path) {
    use flate2::{Compression, write::DeflateEncoder};
    use std::io::Write;
    let path = root.join("vendor").join("LibMP.luau");
    println!("cargo:rerun-if-changed={}", path.display());
    let bytes = fs::read(&path).unwrap_or_default();
    let mut encoder = DeflateEncoder::new(Vec::new(), Compression::best());
    encoder.write_all(&bytes).unwrap();
    fs::write(out.join("LibMP.luau.deflate"), encoder.finish().unwrap()).unwrap();
}

fn package_version(root: &Path) -> String {
    let text = fs::read_to_string(root.join("package.json")).unwrap_or_default();
    // A tiny scan rather than a JSON dependency for one field.
    text.split("\"version\"")
        .nth(1)
        .and_then(|rest| rest.split('"').nth(1))
        .unwrap_or(env!("CARGO_PKG_VERSION"))
        .to_string()
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap()
}

fn collect(dir: &Path, root: &Path, into: &mut Vec<(String, PathBuf)>) {
    for entry in fs::read_dir(dir).unwrap() {
        let entry = entry.unwrap();
        let path = entry.path();
        if path.is_dir() {
            collect(&path, root, into);
        } else if path.extension().is_some_and(|e| e == "luau") {
            let rel = path.strip_prefix(root).unwrap().to_string_lossy().replace('\\', "/");
            into.push((rel, path));
        }
    }
}

struct Node {
    name: String,
    class: &'static str,
    source: Option<String>,
    children: Vec<Node>,
}

fn build_tree(dir: &Path, name: &str, stamp: &str, version: &str) -> Node {
    let mut node = Node { name: name.into(), class: "Folder", source: None, children: vec![] };
    let mut entries: Vec<_> = fs::read_dir(dir).unwrap().map(|e| e.unwrap().path()).collect();
    entries.sort_by_key(|p| {
        let n = p.file_name().unwrap().to_string_lossy().to_string();
        (n.to_lowercase(), n)
    });
    for path in entries {
        let file = path.file_name().unwrap().to_string_lossy().to_string();
        if path.is_dir() {
            node.children.push(build_tree(&path, &file, stamp, version));
            continue;
        }
        if !file.ends_with(".luau") {
            continue;
        }
        let mut source = read(&path);
        if file == "Config.luau" {
            source = source.replace("Config.BUILD_ID = \"dev\"", &format!("Config.BUILD_ID = \"{stamp}\""));
            if let Some(start) = source.find("Config.PLUGIN_VERSION = \"") {
                let value_start = start + "Config.PLUGIN_VERSION = \"".len();
                if let Some(len) = source[value_start..].find('"') {
                    source.replace_range(value_start..value_start + len, version);
                }
            }
        }
        match file.as_str() {
            "init.server.luau" => {
                node.class = "Script";
                node.source = Some(source);
            }
            "init.luau" => {
                node.class = "ModuleScript";
                node.source = Some(source);
            }
            _ => node.children.push(Node {
                name: file.trim_end_matches(".luau").into(),
                class: "ModuleScript",
                source: Some(source),
                children: vec![],
            }),
        }
    }
    node
}

fn escape(value: &str) -> String {
    value.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

fn render(node: &Node, depth: usize, referent: &mut usize, out: &mut String) {
    let pad = "  ".repeat(depth);
    let id = *referent;
    *referent += 1;
    out.push_str(&format!("{pad}<Item class=\"{}\" referent=\"RBX{id}\">\n", node.class));
    out.push_str(&format!("{pad}  <Properties>\n"));
    out.push_str(&format!("{pad}    <string name=\"Name\">{}</string>\n", escape(&node.name)));
    if let Some(source) = &node.source {
        out.push_str(&format!(
            "{pad}    <ProtectedString name=\"Source\"><![CDATA[{}]]></ProtectedString>\n",
            source.replace("]]>", "]]]]><![CDATA[>")
        ));
    }
    if node.class == "Script" {
        out.push_str(&format!("{pad}    <bool name=\"Disabled\">false</bool>\n"));
        out.push_str(&format!("{pad}    <token name=\"RunContext\">0</token>\n"));
    }
    out.push_str(&format!("{pad}  </Properties>\n"));
    for child in &node.children {
        render(child, depth + 1, referent, out);
        out.push('\n');
    }
    out.push_str(&format!("{pad}</Item>"));
}
