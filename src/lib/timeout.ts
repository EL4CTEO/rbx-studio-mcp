import { ToolError } from "./errors.js";

// Node timers overflow above this value and AbortSignal.timeout rejects fractions.
const MAX_TIMER_MS = 2 ** 31 - 1;

/**
 * How long to wait before poll number `attempt` (0-based) of a task that is
 * usually quick but may take a minute: short at first so a fast one is noticed
 * at once, growing to `ceilingMs` so a slow one is not hammered.
 */
export function pollDelayMs(attempt: number, ceilingMs: number, firstMs = 400): number {
  return Math.min(ceilingMs, Math.round(firstMs * 1.6 ** Math.max(0, attempt)));
}

/** Round up so normalization never shortens a caller's budget or its padding. */
export function normalizeTimeoutMs(value: unknown, paddingMs = 0): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0 ||
      !Number.isSafeInteger(paddingMs) || paddingMs < 0 ||
      Math.ceil(value) > MAX_TIMER_MS - paddingMs) {
    throw new ToolError("BAD_TIMEOUT", "timeoutMs must be a finite positive number within Node's timer range.");
  }
  return Math.ceil(value) + paddingMs;
}
