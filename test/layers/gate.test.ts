import { describe, expect, test } from "bun:test";
import { runGate } from "../../src/layers/gate/index";
import { gatePolicy } from "../../src/layers/gate/policy";
import { failsWith, quiet } from "../helpers";

const log = quiet;

describe("the approval gate policy, fail closed", () => {
  test("internal and testers never need an approval", () => {
    expect(gatePolicy("internal", "app-store", "none")).toEqual({});
    expect(gatePolicy("testers", "google-play", "")).toEqual({});
  });
  test("production on a public store needs the store-review gate", async () => {
    expect(gatePolicy("production", "app-store", "store-review")).toEqual({});
    await failsWith(() => gatePolicy("production", "google-play", "none"), "GATE_REQUIRED", /requires gate_layer=store-review/);
    await failsWith(() => gatePolicy("production", "app-store", ""), "GATE_REQUIRED");
  });
  test("production on a private distribution may go without, with a warning; unknown gates and distributions are refused", async () => {
    expect(gatePolicy("production", "firebase", "none").warning).toMatch(/without an external approval gate/);
    expect(gatePolicy("production", "intune", "store-review")).toEqual({});
    await failsWith(() => gatePolicy("production", "firebase", "manual"), "UNKNOWN_GATE");
    await failsWith(() => gatePolicy("production", "my-store", "none"), "UNKNOWN_DISTRIBUTION");
    await failsWith(() => gatePolicy("production", "", "none"), "CONFIGURATION_INCOMPLETE");
  });
});

describe("the gate layers", () => {
  test("none approves, warning on production; store-review is declared but not implemented", async () => {
    const told: any[] = [];
    const step = { explain: (b: any) => told.push(b), link() {}, output() {} };
    expect(await runGate(log, step, "none", "internal", "firebase")).toBe("approved");
    expect(told[0].severity).toBeUndefined();
    expect(await runGate(log, step, "none", "production", "firebase")).toBe("approved");
    expect(told[1].severity).toBe("warn");
    await failsWith(runGate(log, step, "none", "production", "app-store"), "GATE_REQUIRED");
    await failsWith(runGate(log, step, "store-review", "production", "app-store"), "LAYER_NOT_IMPLEMENTED");
    await failsWith(runGate(log, step, "bouncer", "internal", "firebase"), "UNKNOWN_LAYER");
  });
});
