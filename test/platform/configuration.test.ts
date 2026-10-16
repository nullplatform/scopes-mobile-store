import { describe, expect, test } from "bun:test";
import { checkLayer, iamProviderOf, resolveConfiguration } from "../../src/platform/configuration";
import { configuration, failsWith, harness, iam, providers, ROLE_ARN } from "../helpers";

harness();

const ctx = (provs: Record<string, Record<string, unknown>>, scope: Record<string, unknown> = { dimensions: { environment: "uat" } }) =>
  ({
    scope,
    service: {},
    log: { detail() {} },
    settings: { providers: async () => provs, buildContext: async () => ({}) },
  }) as any;

describe("the Mobile store scope configuration", () => {
  test("is the provider resolved for the scope's dimensions, directly or nested under its slug", async () => {
    const direct = await resolveConfiguration(ctx(providers()), "all", {});
    expect(direct.configuration).toMatchObject({ signing_layer: "prebuilt", distribution_layer: "firebase", gate_layer: "none", assets: { bucket: "assets-aws-mobile", region: "us-east-1" } });
    expect(direct.source).toBe("the platform");
    expect(direct.dimensions).toEqual({ environment: "uat" });
    expect(direct.iam).toEqual(iam());
    const nested = await resolveConfiguration(ctx({ "scope-configurations": { "mobile-store": configuration(), other: { marker: 1 } }, "identity-access-control": { "aws-iam": iam() } }), "all", {});
    expect(nested.configuration.firebase?.project).toBe("np-mobile-pc");
    expect(nested.iam?.iam_role_arns?.arns?.[0].arn).toBe(ROLE_ARN);
  });
  test("falls back to environment variables, and the region to us-east-1", async () => {
    const r = await resolveConfiguration(ctx({}), "all", { SIGNING_LAYER: "prebuilt", DISTRIBUTION_LAYER: "firebase", GATE_LAYER: "none", ASSETS_BUCKET: "bucket-x" });
    expect(r.source).toBe("environment variables");
    expect(r.configuration.assets).toEqual({ bucket: "bucket-x", region: "us-east-1" });
  });
  test("another scope type's configuration in the category is not ours", async () => {
    await failsWith(
      resolveConfiguration(ctx({ "scope-configurations": { cluster: "k8s-main", namespace: "apps" } }), "all", {}),
      "CONFIGURATION_INCOMPLETE",
      /missing signing_layer, distribution_layer, gate_layer, assets.bucket/,
    );
  });
  test("an instance listing needs only the distribution and the bucket", async () => {
    const r = await resolveConfiguration(ctx({}), "distribution", { DISTRIBUTION_LAYER: "firebase", ASSETS_BUCKET: "bucket-x" });
    expect(r.configuration.distribution_layer).toBe("firebase");
    await expect(resolveConfiguration(ctx({}), "all", { DISTRIBUTION_LAYER: "firebase", ASSETS_BUCKET: "bucket-x" })).rejects.toThrow(/missing signing_layer, gate_layer/);
  });
  test("refuses values that would reach paths and CLIs malformed", async () => {
    await expect(resolveConfiguration(ctx(providers({ ...configuration(), assets: { bucket: "s3://bucket/path" } })), "all", {})).rejects.toThrow(/invalid assets bucket/);
    await expect(resolveConfiguration(ctx(providers({ ...configuration(), distribution_layer: "Fire Base" })), "all", {})).rejects.toThrow(/invalid distribution layer/);
    await expect(resolveConfiguration(ctx(providers({ ...configuration(), assets: { bucket: "b", region: "us east" } })), "all", {})).rejects.toThrow(/invalid assets region/);
  });
  test("the IAM provider is found whether the category entry is it or nests it", () => {
    expect(iamProviderOf({ "identity-access-control": iam() })).toEqual(iam());
    expect(iamProviderOf({ "identity-access-control": { "aws-iam-configuration": iam(), other: { x: 1 } } })).toEqual(iam());
    expect(iamProviderOf({})).toBeUndefined();
  });
});

describe("the layers", () => {
  test("declared and implemented pass; declared but not implemented, and unknown, say so", async () => {
    expect(checkLayer("signing", "keyvault")).toBe("keyvault");
    await failsWith(() => checkLayer("signing", "match"), "LAYER_NOT_IMPLEMENTED", /'match' is not implemented yet/);
    expect(() => checkLayer("distribution", "app-store")).toThrow(/not implemented yet; this worker implements firebase/);
    await failsWith(() => checkLayer("gate", "approval-bot"), "UNKNOWN_LAYER", /one of none, store-review/);
  });
});
