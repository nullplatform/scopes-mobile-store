import { describe, expect, test } from "bun:test";
import { Actions } from "@nullplatform/plugin/package";
import pkg from "../../src/package";
import { target } from "../../src/scope/resources";
import { APP_ID_ANDROID, configuration, deployment, given, harness, PROJECT_NUMBER, providers, scope } from "../helpers";

const h = harness();
const steps = (run: { steps: Array<{ key: string }> }) => run.steps.map((s) => s.key);

describe("create-scope and update-scope", () => {
  test("check the configuration and the layers, and set the asset name a scope created through the API lacks", async () => {
    delete h.platform.scopes["7"].asset_name;
    const run = await pkg.run(target, Actions.CREATE_SCOPE, { scope_id: "7" }, given({ platform: "both" }, { scope: { ...scope, asset_name: undefined } }));
    expect(run.error).toBeUndefined();
    expect(steps(run)).toEqual(["resolve configuration", "ensure asset name"]);
    expect(h.platform.patched).toEqual([{ id: "7", body: { asset_name: "android" } }]);
    expect(run.logs.some((l) => l.includes("asset name android (the scope had none; set to its first platform)"))).toBe(true);
    expect(run.logs.some((l) => l.includes("signing layer 'prebuilt' is available"))).toBe(true);
  });
  test("keep a valid asset name, and refuse one the other platform cannot be derived from", async () => {
    h.platform.scopes["7"].asset_name = "android-internal";
    const ok = await pkg.run(target, Actions.UPDATE_SCOPE, { scope_id: "7" }, given({ platform: "both" }, { scope: { ...scope, asset_name: "android-internal" } }));
    expect(ok.status).toBe("success");
    expect(h.platform.patched).toEqual([]);
    const bad = await pkg.run(target, Actions.UPDATE_SCOPE, { scope_id: "7" }, given({ platform: "both" }, { scope: { ...scope, asset_name: "mobile-prod" } }));
    expect(bad.error).toMatchObject({ code: "ASSET_NAME_UNDERIVABLE" });
    expect(bad.error?.message).toContain("np scope patch --id 7");
  });
  test("an ios scope without an asset name deploys 'ios'", async () => {
    delete h.platform.scopes["7"].asset_name;
    const run = await pkg.run(target, Actions.CREATE_SCOPE, { scope_id: "7" }, given({ platform: "ios" }, { scope: { ...scope, asset_name: undefined } }));
    expect(run.status).toBe("success");
    expect(h.platform.patched).toEqual([{ id: "7", body: { asset_name: "ios" } }]);
  });
  test("fail before any deployment needs them: a missing configuration, an unknown or unimplemented layer", async () => {
    const missing = await pkg.run(target, Actions.CREATE_SCOPE, { scope_id: "7" }, given({}, { providers: {} }));
    expect(missing.error).toMatchObject({ code: "CONFIGURATION_INCOMPLETE" });
    const unknown = await pkg.run(target, Actions.CREATE_SCOPE, { scope_id: "7" }, given({}, { providers: providers({ ...configuration(), gate_layer: "slack-approval" }) }));
    expect(unknown.error).toMatchObject({ code: "UNKNOWN_LAYER" });
    const later = await pkg.run(target, Actions.CREATE_SCOPE, { scope_id: "7" }, given({}, { providers: providers({ ...configuration(), distribution_layer: "intune" }) }));
    expect(later.error).toMatchObject({ code: "LAYER_NOT_IMPLEMENTED" });
    expect(h.platform.patched).toEqual([]);
  });
});

describe("delete-scope", () => {
  test("has nothing to remove", async () => {
    const run = await pkg.run(target, Actions.DELETE_SCOPE, { scope_id: "7" }, given());
    expect(run.status).toBe("success");
    expect(run.logs.some((l) => l.includes("nothing to do"))).toBe(true);
    expect(h.http.calls).toHaveLength(0);
  });
});

describe("instance:data", () => {
  test("answers the releases of the channel's apps, listed with the service account under the scope's role", async () => {
    h.firebase.releases[APP_ID_ANDROID] = [{ name: `projects/${PROJECT_NUMBER}/apps/${APP_ID_ANDROID}/releases/0abc`, displayVersion: "1.0.0", buildVersion: "10", createTime: "2025-12-22T18:30:00Z" }];
    const run = await pkg.run(target, Actions.INSTANCE_DATA, { scope_id: "7" }, given());
    expect(run.error).toBeUndefined();
    expect(run.raw).toBe(true);
    expect(run.data).toEqual({
      results: [{ platform: "android", app_id: APP_ID_ANDROID, release: `projects/${PROJECT_NUMBER}/apps/${APP_ID_ANDROID}/releases/0abc`, version: "1.0.0", build: "10", created_at: "2025-12-22T18:30:00Z", release_notes: null, console_url: null, testing_url: null }],
    });
    expect(h.aws.assumed).toHaveLength(1);
  });
  test("needs only the distribution side of the configuration (environment variables, when no configuration is registered)", async () => {
    const { deps } = await import("../../src/deps");
    Object.assign(deps.env, { DISTRIBUTION_LAYER: "firebase", ASSETS_BUCKET: "assets-aws-mobile" });
    // No signing nor gate layer anywhere: an instance listing never signs nor gates. The Firebase section still has to come from somewhere.
    const run = await pkg.run(target, Actions.INSTANCE_DATA, { scope_id: "7" }, given({}, { providers: { "scope-configurations": { distribution_layer: "firebase", firebase: configuration().firebase, assets: configuration().assets } } }));
    expect(run.error).toBeUndefined();
    expect(run.data).toEqual({ results: [] });
    const deploy = await pkg.run(target, Actions.START_INITIAL, deployment, given({}, { providers: { "scope-configurations": { distribution_layer: "firebase", firebase: configuration().firebase, assets: configuration().assets } } }));
    expect(deploy.error).toMatchObject({ code: "CONFIGURATION_INCOMPLETE" });
    expect(deploy.error?.message).toContain("missing signing_layer, gate_layer");
  });
});
