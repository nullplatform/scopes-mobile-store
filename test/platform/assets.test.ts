import { describe, expect, test } from "bun:test";
import { assetNames, buildAssets, ensureAssetName, platformAssetName, releaseAssets, resolveAssetName, validateAssetName } from "../../src/platform/assets";
import { APK_URL, failsWith, harness, IPA_URL, PREVIOUS_APK_URL } from "../helpers";

const h = harness();
const ctx = (scope?: Record<string, unknown>) => ({ api: {}, scope }) as any;

describe("asset names", () => {
  test("must be lowercase names starting with a letter or digit", async () => {
    for (const ok of ["android", "ios", "android-internal", "mobile.prod_1"]) expect(() => validateAssetName(ok, "android")).not.toThrow();
    for (const bad of ["Android", "-android", "android internal", ""]) await failsWith(() => validateAssetName(bad, "android", "7"), "INVALID_ASSET_NAME", /np scope patch --id 7/);
  });
  test("the other platform of a 'both' scope swaps the platform prefix, or cannot be derived", async () => {
    expect(platformAssetName("android", "android", "android")).toBe("android");
    expect(platformAssetName("android", "android", "ios")).toBe("ios");
    expect(platformAssetName("android-internal", "android", "ios")).toBe("ios-internal");
    expect(platformAssetName("ios-beta", "ios", "android")).toBe("android-beta");
    for (const bad of ["mobile-prod", "androidtv-prod", "android2"]) {
      await failsWith(() => platformAssetName(bad, "android", "ios", "7"), "ASSET_NAME_UNDERIVABLE", /'android' or 'android-<suffix>'/);
    }
    expect(assetNames("android-internal", ["android", "ios"])).toEqual({ android: "android-internal", ios: "ios-internal" });
  });
});

describe("the scope's asset name", () => {
  test("comes from the notification's scope, else the scope as the platform holds it, else the first platform", async () => {
    expect(await resolveAssetName(ctx({ asset_name: "android-internal" }), "7", "android")).toEqual({ name: "android-internal", source: "context" });
    h.platform.scopes["7"].asset_name = "android-qa";
    expect(await resolveAssetName(ctx({}), "7", "android")).toEqual({ name: "android-qa", source: "scope" });
    delete h.platform.scopes["7"].asset_name;
    expect(await resolveAssetName(ctx({}), "7", "ios")).toEqual({ name: "ios", source: "default" });
  });
  test("a scope that cannot be read fails the action instead of guessing the binary", async () => {
    h.platform.fail.scope = "401 unauthorized";
    await failsWith(resolveAssetName(ctx({}), "7", "android"), "SCOPE_UNREADABLE", /could not read scope 7/);
  });
  test("create-scope sets the first platform's name when the scope has none, and keeps a valid one", async () => {
    delete h.platform.scopes["7"].asset_name;
    expect(await ensureAssetName(ctx({}), "7", ["android", "ios"])).toEqual({ name: "android", set: true });
    expect(h.platform.patched).toEqual([{ id: "7", body: { asset_name: "android" } }]);
    expect(await ensureAssetName(ctx({ asset_name: "android-internal" }), "7", ["android", "ios"])).toEqual({ name: "android-internal", set: false });
    expect(h.platform.patched).toHaveLength(1);
  });
  test("an existing name the other platform cannot be derived from fails create-scope", async () => {
    await failsWith(ensureAssetName(ctx({ asset_name: "mobile-prod" }), "7", ["android", "ios"]), "ASSET_NAME_UNDERIVABLE");
  });
  test("a scope that cannot be patched fails create-scope: without an asset name no deployment works", async () => {
    delete h.platform.scopes["7"].asset_name;
    h.platform.fail.patch = "403 forbidden";
    await failsWith(ensureAssetName(ctx({}), "7", ["android"]), "ASSET_NAME_NOT_SET");
  });
});

describe("the binaries of a release", () => {
  test("are the build's assets named for each platform, of the scope's asset type", async () => {
    const found = await buildAssets(ctx(), "10", { android: "android", ios: "ios" }, "1.0.0");
    expect(found.map((a) => [a.platform, a.url])).toEqual([
      ["android", APK_URL],
      ["ios", IPA_URL],
    ]);
  });
  test("a missing asset names what the CI must register", async () => {
    await failsWith(buildAssets(ctx(), "10", { android: "android-internal" } as any, "1.0.0"), "NO_ASSET", /named 'android-internal' of type 'bundle' in release 1.0.0/);
  });
  test("a rollback finds the previous release's binaries by semver", async () => {
    const found = await releaseAssets(ctx(), "442353687", "0.9.0", { android: "android" } as any);
    expect(found[0].url).toBe(PREVIOUS_APK_URL);
    await failsWith(releaseAssets(ctx(), "442353687", "0.1.0", { android: "android" } as any), "NO_RELEASE");
  });
});
