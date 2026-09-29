/**
 * Things that happened in the background that the agent should hear about.
 *
 * A running `sync watch` finds conflicts and errors between tool calls, when
 * nobody is asking. Left in `status` alone they wait until someone thinks to
 * look -- usually after building on top of a file that never reached Studio.
 * So they queue here and ride along on the next tool reply, whatever the tool.
 *
 * Its own module because the tool wrapper has to read it and the sync engine
 * writes it, and neither should import the other.
 */

const queue: string[] = [];
const LIMIT = 10;

export function pushNotice(message: string): void {
  if (queue.includes(message)) return;
  queue.push(message);
  if (queue.length > LIMIT) queue.shift();
}

/** Everything queued, as one block, or undefined; empties the queue. */
export function takeNotices(): string | undefined {
  if (queue.length === 0) return undefined;
  const text = queue.map((line) => `- ${line}`).join("\n");
  queue.length = 0;
  return `[sync watch]\n${text}`;
}
