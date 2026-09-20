import { ToolError } from "./errors.js";

// Node timers overflow above this value and AbortSignal.timeout rejects fractions.
const MAX_TIMER_MS = 2 ** 31 - 1;

/** Round up so normalization never shortens a caller's budget or its padding. */
export function normalizeTimeoutMs(value: unknown, paddingMs = 0): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0 ||
      !Number.isSafeInteger(paddingMs) || paddingMs < 0 ||
      Math.ceil(value) > MAX_TIMER_MS - paddingMs) {
    throw new ToolError("BAD_TIMEOUT", "timeoutMs must be a finite positive number within Node's timer range.");
  }
  return Math.ceil(value) + paddingMs;
}
