/**
 * A thin runner around the command-line tools the scope drives (firebase,
 * apksigner): one spawn per command, both streams forwarded line by line to
 * the action's log, and an exit code plus stderr turned into an ActionError
 * the platform, the trace and the tests read by name. Whatever looks like a
 * secret among the variables handed to a tool never reaches the log.
 */

import { ActionError } from "@nullplatform/plugin/package";

export type Stream = "stdout" | "stderr";

export interface CliOptions {
  /** The variables the tool reads (credentials file, passwords); redacted from the log. */
  env?: Record<string, string>;
  cwd?: string;
  /** Kills the tool when the worker is told to stop. */
  signal?: AbortSignal;
  onLine?: (line: string, stream: Stream) => void;
}

export interface CliResult {
  bin: string;
  args: string[];
  stdout: string;
  stderr: string;
  exitCode: number;
}

export type Runner = (bin: string, args: string[], opts?: CliOptions) => Promise<CliResult>;

export const run: Runner = async (bin, args, opts = {}) => {
  let proc: ReturnType<typeof Bun.spawn>;
  try {
    proc = Bun.spawn([bin, ...args], {
      cwd: opts.cwd,
      env: { ...process.env, ...(opts.env ?? {}), NO_COLOR: "1", CI: "1" },
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
  } catch (err) {
    throw new ActionError("CLI_MISSING", `cannot start ${bin}: ${err instanceof Error ? err.message : String(err)}`);
  }
  const redact = redactor(opts.env ?? {});
  const onLine = opts.onLine && ((line: string, stream: Stream) => opts.onLine!(redact(line), stream));
  const abort = () => proc.kill("SIGTERM");
  if (opts.signal?.aborted) abort();
  opts.signal?.addEventListener("abort", abort, { once: true });
  try {
    const [stdout, stderr, exitCode] = await Promise.all([
      drain(proc.stdout as ReadableStream<Uint8Array>, "stdout", onLine),
      drain(proc.stderr as ReadableStream<Uint8Array>, "stderr", onLine),
      proc.exited,
    ]);
    if (opts.signal?.aborted) throw new ActionError("CANCELLED", `${bin} ${args[0] ?? ""} was cancelled`);
    return { bin, args, stdout, stderr, exitCode };
  } finally {
    opts.signal?.removeEventListener("abort", abort);
  }
};

const SECRET_KEY = /TOKEN|SECRET|PASSWORD|ASSERTION|CREDENTIAL/i;

/** Replaces the values of the secret-looking variables with `***`, so a tool that echoes them is safe to log. */
export function redactor(env: Record<string, string>): (line: string) => string {
  const secrets = Object.entries(env)
    .filter(([key, value]) => SECRET_KEY.test(key) && value.length >= 4)
    .map(([, value]) => value);
  if (!secrets.length) return (line) => line;
  return (line) => secrets.reduce((acc, secret) => acc.split(secret).join("***"), line);
}

async function drain(stream: ReadableStream<Uint8Array>, name: Stream, onLine?: CliOptions["onLine"]): Promise<string> {
  const chunks: string[] = [];
  let pending = "";
  const decoder = new TextDecoder();
  for await (const chunk of stream) {
    const piece = decoder.decode(chunk, { stream: true });
    chunks.push(piece);
    pending += piece;
    const lines = pending.split("\n");
    pending = lines.pop() ?? "";
    for (const line of lines) if (line.trim()) onLine?.(line, name);
  }
  if (pending.trim()) onLine?.(pending, name);
  return chunks.join("");
}

/** The tool's last words, for an error message: the tail of stderr (else stdout), one line, bounded. */
export function lastWords(result: Pick<CliResult, "stdout" | "stderr">, lines = 3): string {
  return (result.stderr.trim() || result.stdout.trim())
    .split("\n")
    .filter((l) => l.trim())
    .slice(-lines)
    .join(" ")
    .slice(0, 600);
}

/** `--output json` parsed; a tool sometimes prefixes JSON with progress lines. */
export function parseJson<T>(result: CliResult): T {
  const raw = result.stdout.trim();
  const start = raw.search(/[[{]/);
  try {
    return JSON.parse(start > 0 ? raw.slice(start) : raw) as T;
  } catch {
    throw new ActionError(
      "CLI_FAILED",
      `${result.bin} ${result.args[0] ?? ""} did not return JSON: ${raw.slice(0, 200)}`,
    );
  }
}
