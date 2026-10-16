import { describe, expect, test } from "bun:test";
import { mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { deploymentWorkdir, removeWorkdir, scopeWorkdir, workdirBase } from "../../src/platform/workdir";

describe("the scratch directories", () => {
  test("live under MOBILE_STORE_WORKDIR, else WORKDIR, else the system's temporary directory", () => {
    expect(workdirBase({ MOBILE_STORE_WORKDIR: "/scratch" })).toBe("/scratch");
    expect(workdirBase({ WORKDIR: "/tmp/mobile-store" })).toBe("/tmp/mobile-store");
    expect(workdirBase({})).toBe(join(tmpdir(), "mobile-store"));
  });
  test("a deployment's is private and shared by its re-runs; a scope listing's is fresh per run; removal never leaves the base", async () => {
    const base = await mkdtemp(join(tmpdir(), "ws-"));
    try {
      const a = await deploymentWorkdir("77", base);
      expect(a).toBe(join(base, "77"));
      expect((await stat(a)).mode & 0o777).toBe(0o700);
      expect(await deploymentWorkdir("77", base)).toBe(a);
      const s1 = await scopeWorkdir("7", base);
      const s2 = await scopeWorkdir("7", base);
      expect(s1).not.toBe(s2);
      await writeFile(join(a, "app.apk"), "x");
      expect(await removeWorkdir(a, base)).toBe(true);
      await expect(stat(a)).rejects.toThrow();
      expect(await removeWorkdir(base, base)).toBe(false);
      expect(await removeWorkdir("/etc", base)).toBe(false);
      expect(await removeWorkdir(join(base, "..", "elsewhere"), base)).toBe(false);
    } finally {
      await rm(base, { recursive: true, force: true });
    }
  });
});
