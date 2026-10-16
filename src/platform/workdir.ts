/**
 * The scratch directories: one per deployment, where binaries are downloaded
 * and signed and where the distribution credentials live for the length of a
 * step, and one per instance:data run (two concurrent requests never share
 * credentials). Private (mode 700); removed by delete-deployment, or at the
 * end of the run for an instance listing.
 */

import { chmod, mkdir, mkdtemp, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

/** The base: MOBILE_STORE_WORKDIR, the operator's WORKDIR, else the system's temporary directory. */
export function workdirBase(env: Record<string, string | undefined> = process.env): string {
  return env.MOBILE_STORE_WORKDIR || env.WORKDIR || join(tmpdir(), "mobile-store");
}

/** `<base>/<deployment id>`, created private; re-runs of the same deployment share it. */
export async function deploymentWorkdir(deploymentId: string, base = workdirBase()): Promise<string> {
  const dir = join(base, deploymentId);
  await mkdir(dir, { recursive: true, mode: 0o700 });
  await chmod(dir, 0o700);
  return dir;
}

/** `<base>/scope-<id>-XXXXXX`, fresh per run. */
export async function scopeWorkdir(scopeId: string, base = workdirBase()): Promise<string> {
  await mkdir(base, { recursive: true });
  const dir = await mkdtemp(join(base, `scope-${scopeId}-`));
  await chmod(dir, 0o700);
  return dir;
}

/** Removes a scratch directory, but only one under the base: nothing else is ever deleted. */
export async function removeWorkdir(dir: string, base = workdirBase()): Promise<boolean> {
  const target = resolve(dir);
  const root = resolve(base);
  if (target === root || !target.startsWith(root + "/")) return false;
  try {
    await stat(target);
  } catch {
    return false;
  }
  await rm(target, { recursive: true, force: true });
  return true;
}
