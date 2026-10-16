import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { fetchBinary, locateAsset } from "../../src/layers/binaries/fetch";
import { zipEntries } from "../../src/layers/binaries/zip";
import { apk, APK_URL, BUCKET, failsWith, harness, ipa, plainZip, quiet, silentStep } from "../helpers";

const h = harness();
const log = quiet;
const step = silentStep;
const opts = () => ({ bucket: BUCKET, region: "us-east-1" });
const asset = (platform: "android" | "ios", url: string) => ({ platform, name: platform, url });

describe("where an asset is", () => {
  test("inside the configured bucket: s3:// or its virtual-hosted https url", () => {
    expect(locateAsset(`s3://${BUCKET}/mobile/1/app.apk`, BUCKET)).toEqual({ kind: "s3", bucket: BUCKET, key: "mobile/1/app.apk" });
    expect(locateAsset(`https://${BUCKET}.s3.amazonaws.com/mobile/1/app.apk`, BUCKET)).toEqual({ kind: "https", url: `https://${BUCKET}.s3.amazonaws.com/mobile/1/app.apk` });
    expect(locateAsset(`https://${BUCKET}.s3.us-east-1.amazonaws.com/mobile/1/app.apk`, BUCKET).kind).toBe("https");
  });
  test("anywhere else is refused: the agent role is broader than one scope", async () => {
    expect(() => locateAsset("s3://other-bucket/app.apk", BUCKET)).toThrow(/outside the configured assets bucket/);
    expect(() => locateAsset(`s3://${BUCKET}`, BUCKET)).toThrow(/outside the configured assets bucket/);
    expect(() => locateAsset("https://evil.example.com/app.apk", BUCKET)).toThrow(/outside the configured assets bucket/);
    expect(() => locateAsset(`https://${BUCKET}.s3.amazonaws.com/`, BUCKET)).toThrow(/outside the configured assets bucket/);
    await failsWith(() => locateAsset("ftp://x/app.apk", BUCKET), "UNSUPPORTED_ASSET_URL");
  });
});

describe("a zip's table of contents", () => {
  test("lists the entries of an APK, an IPA and a plain zip; anything else is not a zip", async () => {
    await Bun.write(join(h.dir, "a.apk"), apk());
    await Bun.write(join(h.dir, "a.ipa"), ipa());
    await Bun.write(join(h.dir, "a.zip"), plainZip());
    await Bun.write(join(h.dir, "a.txt"), "just text, long enough to be scanned for an end record".repeat(4));
    expect(await zipEntries(join(h.dir, "a.apk"))).toEqual(["AndroidManifest.xml", "classes.dex"]);
    expect(await zipEntries(join(h.dir, "a.ipa"))).toContain("Payload/Sample.app/Info.plist");
    expect(await zipEntries(join(h.dir, "a.zip"))).toEqual(["readme.txt"]);
    await failsWith(zipEntries(join(h.dir, "a.txt")), "NOT_A_ZIP", /not a zip archive/);
  });
});

describe("the binary of a platform", () => {
  test("is downloaded from S3 with the scope's credentials and checked to be an APK or an IPA", async () => {
    const android = await fetchBinary(log, step, asset("android", APK_URL), h.dir, { ...opts(), credentials: { accessKeyId: "a", secretAccessKey: "b" } });
    expect(android.path).toBe(join(h.dir, "android", "app.apk"));
    expect(Bun.file(android.path).size).toBe(apk().length);
    h.aws.objects[`s3://${BUCKET}/x/app.ipa`] = ipa();
    const ios = await fetchBinary(log, step, asset("ios", `s3://${BUCKET}/x/app.ipa`), h.dir, opts());
    expect(ios.path).toBe(join(h.dir, "ios", "app.ipa"));
  });
  test("or over https from the bucket's own host", async () => {
    h.aws.objects[`s3://${BUCKET}/https/app.apk`] = apk();
    const b = await fetchBinary(log, step, asset("android", `https://${BUCKET}.s3.amazonaws.com/https/app.apk`), h.dir, opts());
    expect(Bun.file(b.path).size).toBe(apk().length);
    expect(h.http.calls.map((c) => c.url)).toEqual([`https://${BUCKET}.s3.amazonaws.com/https/app.apk`]);
  });
  test("a zip that is not a mobile binary, or no zip at all, names what the CI must upload", async () => {
    h.aws.objects[`s3://${BUCKET}/bad/app.apk`] = plainZip();
    await failsWith(fetchBinary(log, step, asset("android", `s3://${BUCKET}/bad/app.apk`), h.dir, opts()), "NOT_A_MOBILE_BINARY", /not an Android package/);
    h.aws.objects[`s3://${BUCKET}/text/app.ipa`] = new TextEncoder().encode("hello");
    await failsWith(fetchBinary(log, step, asset("ios", `s3://${BUCKET}/text/app.ipa`), h.dir, opts()), "NOT_A_MOBILE_BINARY", /not a zip archive/);
  });
  test("a failed download says which bucket the role must read", async () => {
    h.aws.s3Error = "AccessDenied";
    await failsWith(fetchBinary(log, step, asset("android", APK_URL), h.dir, opts()), "ASSET_DOWNLOAD_FAILED", /AccessDenied/);
  });
});
