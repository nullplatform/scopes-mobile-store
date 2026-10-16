import { describe, expect, test } from "bun:test";
import { stat } from "node:fs/promises";
import { join } from "node:path";
import { sign } from "../../src/layers/signing/index";
import { parseKeystoreSecret } from "../../src/layers/signing/keyvault";
import { configuration, failsWith, harness, KEYSTORE_SECRET, quiet } from "../helpers";

const h = harness();
const log = quiet;
const explained: unknown[] = [];
const step = { explain: (b: unknown) => explained.push(b), link() {}, output() {} };
const binaries = () => [
  { platform: "android" as const, path: join(h.dir, "android", "app.apk"), asset: { platform: "android" as const, name: "android", url: "s3://b/k" } },
];
const opts = { region: "us-east-1" };

describe("prebuilt", () => {
  test("uses the CI-signed binaries as they are", async () => {
    const signed = await sign(log, step, "prebuilt", [...binaries(), { platform: "ios", path: "/w/ios/app.ipa", asset: { platform: "ios", name: "ios", url: "s3://b/i" } }], configuration() as any, opts);
    expect(signed.map((s) => s.signedPath)).toEqual([join(h.dir, "android", "app.apk"), "/w/ios/app.ipa"]);
    expect(h.cli.calls).toHaveLength(0);
  });
});

describe("keyvault", () => {
  test("signs the Android binary with the keystore from the secret: passwords through the environment, never argv; the keystore is removed", async () => {
    await Bun.write(join(h.dir, "android", "app.apk"), "apk");
    const signed = await sign(log, step, "keyvault", binaries(), configuration() as any, { ...opts, credentials: { accessKeyId: "a", secretAccessKey: "b" } });
    expect(signed[0].signedPath).toBe(join(h.dir, "android", "app-signed.apk"));
    const [signCall, verifyCall] = h.cli.calls;
    expect(signCall.bin).toBe("apksigner");
    expect(signCall.args).toEqual([
      "sign",
      "--ks",
      join(h.dir, "android", "keystore.jks"),
      "--ks-pass",
      "env:MOBILE_STORE_KEYSTORE_PASSWORD",
      "--ks-key-alias",
      "release",
      "--key-pass",
      "env:MOBILE_STORE_KEY_PASSWORD",
      "--out",
      join(h.dir, "android", "app-signed.apk"),
      join(h.dir, "android", "app.apk"),
    ]);
    expect(signCall.env).toEqual({ MOBILE_STORE_KEYSTORE_PASSWORD: "k3yst0re-s3cret", MOBILE_STORE_KEY_PASSWORD: "k3y-s3cret" });
    expect(JSON.stringify(signCall.args)).not.toContain("s3cret");
    expect(verifyCall.args).toEqual(["verify", join(h.dir, "android", "app-signed.apk")]);
    await expect(stat(join(h.dir, "android", "keystore.jks"))).rejects.toThrow();
  });
  test("refuses ios until it supports it, and a scope configuration without a keystore secret", async () => {
    await failsWith(sign(log, step, "keyvault", [{ platform: "ios", path: "/w/ios/app.ipa", asset: { platform: "ios", name: "ios", url: "u" } }], configuration() as any, opts), "IOS_SIGNING_NOT_IMPLEMENTED");
    await failsWith(sign(log, step, "keyvault", binaries(), { ...configuration(), android: {} } as any, opts), "CONFIGURATION_INCOMPLETE", /android.keystore_secret/);
    await failsWith(sign(log, step, "keyvault", binaries(), { ...configuration(), android: { keystore_secret: "prod/keystore" } } as any, opts), "SECRET_OUTSIDE_NAMESPACE", /mobile\//);
  });
  test("a secret that is not a keystore secret, and apksigner failing, name the fix", async () => {
    await failsWith(() => parseKeystoreSecret(KEYSTORE_SECRET, '{"keystore_base64":"","key_alias":"a"}'), "INVALID_KEYSTORE_SECRET");
    await failsWith(() => parseKeystoreSecret(KEYSTORE_SECRET, "not json"), "INVALID_KEYSTORE_SECRET");
    h.aws.secrets[KEYSTORE_SECRET] = JSON.stringify({ keystore_base64: "!!!not-base64", keystore_password: "", key_alias: "a", key_password: "" });
    await failsWith(sign(log, step, "keyvault", binaries(), configuration() as any, opts), "INVALID_KEYSTORE_SECRET", /not valid base64/);
    h.aws.secrets[KEYSTORE_SECRET] = JSON.stringify({ keystore_base64: Buffer.from("jks").toString("base64"), keystore_password: "x", key_alias: "a", key_password: "y" });
    h.cli.answers.apksigner = (args) => (args[0] === "sign" ? { exitCode: 1, stderr: "Failed to load signer: keystore password was incorrect" } : {});
    await failsWith(sign(log, step, "keyvault", binaries(), configuration() as any, opts), "SIGNING_FAILED", /keystore password was incorrect/);
    h.cli.answers.apksigner = (args) => (args[0] === "verify" ? { exitCode: 1, stderr: "DOES NOT VERIFY" } : {});
    await failsWith(sign(log, step, "keyvault", binaries(), configuration() as any, opts), "SIGNATURE_INVALID");
    delete h.aws.secrets[KEYSTORE_SECRET];
    await failsWith(sign(log, step, "keyvault", binaries(), configuration() as any, opts), "SECRET_UNREADABLE");
  });
});
