import { describe, expect, test } from "bun:test";
import { createVerify } from "node:crypto";
import { join } from "node:path";
import { distributeAll, newSummary } from "../../src/layers/distribution/firebase/distribute";
import { parseServiceAccount, setupFirebase, validateFirebaseAppId, validateFirebaseProject } from "../../src/layers/distribution/firebase/index";
import { listReleases } from "../../src/layers/distribution/firebase/releases";
import { accessToken, assertionFor, GOOGLE_TOKEN_URI } from "../../src/layers/distribution/firebase/token";
import { APP_ID_ANDROID, APP_ID_IOS, configuration, failsWith, FIREBASE_PROJECT, harness, PROJECT_NUMBER, quiet, SA_SECRET, serviceAccount } from "../helpers";

const h = harness();
const log = quiet;
const told: any[] = [];
const step = { explain: (b: any) => told.push(b), link: (l: any) => told.push(l), output: (k: string, v: unknown) => told.push({ [k]: v }) };
const opts = { region: "us-east-1" };

describe("the Firebase setup", () => {
  test("validates the configuration for the scope's platforms and reads the service account into memory", async () => {
    const fb = await setupFirebase(log, step, configuration() as any, ["android", "ios"], opts);
    expect(fb).toMatchObject({ project: FIREBASE_PROJECT, appIds: { android: APP_ID_ANDROID, ios: APP_ID_IOS }, secretName: SA_SECRET });
    expect(fb.account.client_email).toBe(`distributor@${FIREBASE_PROJECT}.iam.gserviceaccount.com`);
    expect(await Bun.file(join(h.dir, "firebase-sa.json")).exists()).toBe(false);
  });
  test("lists every missing field at once, per platform", async () => {
    const cfg = { ...configuration(), firebase: { app_id_android: APP_ID_ANDROID } } as any;
    await expect(setupFirebase(log, step, cfg, ["android", "ios"], opts)).rejects.toThrow(/missing firebase.project, firebase.credentials_secret, firebase.app_id_ios/);
  });
  test("refuses ids and names that are not what they claim", () => {
    expect(() => validateFirebaseProject("My Project")).toThrow(/not a Firebase project id/);
    expect(() => validateFirebaseAppId("android", APP_ID_IOS)).toThrow(/not a Firebase android app id/);
    expect(() => validateFirebaseAppId("ios", "1:123:ios:xyz")).toThrow(/not a Firebase ios app id/);
    expect(() => parseServiceAccount(SA_SECRET, JSON.stringify({ client_email: "x" }))).toThrow(/not a Google service account JSON/);
  });
  test("the credentials secret must live under mobile/, exist and be a service account", async () => {
    await failsWith(setupFirebase(log, step, { ...configuration(), firebase: { ...configuration().firebase, credentials_secret: "prod/sa" } } as any, ["android"], opts), "SECRET_OUTSIDE_NAMESPACE");
    delete h.aws.secrets[SA_SECRET];
    await failsWith(setupFirebase(log, step, configuration() as any, ["android"], opts), "SECRET_UNREADABLE");
    h.aws.secrets[SA_SECRET] = "not json";
    await failsWith(setupFirebase(log, step, configuration() as any, ["android"], opts), "NOT_A_SERVICE_ACCOUNT");
  });
});

describe("the Google access token", () => {
  test("is a JWT the account's key signed, exchanged only at Google's token endpoint", async () => {
    const account = serviceAccount();
    const assertion = assertionFor(account, 1_700_000_000);
    const [header, claims, signature] = assertion.split(".");
    expect(JSON.parse(Buffer.from(header, "base64url").toString())).toEqual({ alg: "RS256", typ: "JWT" });
    expect(JSON.parse(Buffer.from(claims, "base64url").toString())).toEqual({
      iss: account.client_email,
      scope: "https://www.googleapis.com/auth/cloud-platform",
      aud: GOOGLE_TOKEN_URI,
      iat: 1_700_000_000,
      exp: 1_700_003_600,
    });
    const publicKey = (await import("node:crypto")).createPublicKey(account.private_key);
    expect(createVerify("RSA-SHA256").update(`${header}.${claims}`).verify(publicKey, Buffer.from(signature, "base64url"))).toBe(true);
    expect(await accessToken(account)).toBe("ya29.test");
    const call = h.http.calls[0];
    expect(call.url).toBe(GOOGLE_TOKEN_URI);
    expect(String(call.body)).toContain("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer");
    expect(String(call.body)).not.toContain(account.private_key.slice(30, 60));
  });
  test("refuses a key whose token_uri is anywhere else, and says when Google refuses", async () => {
    await expect(accessToken({ ...serviceAccount(), token_uri: "https://evil.example.com/token" })).rejects.toThrow(/only https:\/\/oauth2.googleapis.com\/token is allowed/);
    h.firebase.tokenStatus = 400;
    await failsWith(accessToken(serviceAccount()), "GOOGLE_TOKEN_FAILED", /HTTP 400/);
  });
});

describe("distributing a release", () => {
  const signed = () => [
    { platform: "android" as const, path: "/w/android/app.apk", signedPath: join(h.dir, "app.apk"), asset: { platform: "android" as const, name: "android", url: "u" } },
    { platform: "ios" as const, path: "/w/ios/app.ipa", signedPath: join(h.dir, "app.ipa"), asset: { platform: "ios" as const, name: "ios", url: "u" } },
  ];
  const setup = async (platforms: Array<"android" | "ios"> = ["android", "ios"]) => {
    await Bun.write(join(h.dir, "app.apk"), "apk-bytes");
    await Bun.write(join(h.dir, "app.ipa"), "ipa-bytes");
    return setupFirebase(log, step, configuration() as any, platforms, opts);
  };
  test("uploads, waits for the operation, sets the release notes and distributes to the channel's group, per platform", async () => {
    const fb = await setup();
    h.firebase.pollsBeforeDone = 1;
    const summary = await distributeAll(log, step, fb, signed(), "internal", newSummary(fb, "internal"), { releaseNotes: "sample 1.0.0 (uat) deployment 77" });
    const calls = h.http.calls.filter((c) => c.url !== GOOGLE_TOKEN_URI);
    expect(calls.map((c) => `${c.method} ${c.url.replace("https://firebaseappdistribution.googleapis.com", "")}`)).toEqual([
      `POST /upload/v1/projects/${PROJECT_NUMBER}/apps/${APP_ID_ANDROID}/releases:upload`,
      `GET /v1/projects/${PROJECT_NUMBER}/apps/${APP_ID_ANDROID}/operations/op-android`,
      `GET /v1/projects/${PROJECT_NUMBER}/apps/${APP_ID_ANDROID}/operations/op-android`,
      `PATCH /v1/projects/${PROJECT_NUMBER}/apps/${APP_ID_ANDROID}/releases/rel-android?updateMask=release_notes.text`,
      `POST /v1/projects/${PROJECT_NUMBER}/apps/${APP_ID_ANDROID}/releases/rel-android:distribute`,
      `POST /upload/v1/projects/${PROJECT_NUMBER}/apps/${APP_ID_IOS}/releases:upload`,
      `GET /v1/projects/${PROJECT_NUMBER}/apps/${APP_ID_IOS}/operations/op-ios`,
      `GET /v1/projects/${PROJECT_NUMBER}/apps/${APP_ID_IOS}/operations/op-ios`,
      `PATCH /v1/projects/${PROJECT_NUMBER}/apps/${APP_ID_IOS}/releases/rel-ios?updateMask=release_notes.text`,
      `POST /v1/projects/${PROJECT_NUMBER}/apps/${APP_ID_IOS}/releases/rel-ios:distribute`,
    ]);
    const upload = calls[0];
    expect(upload.headers).toMatchObject({ authorization: "Bearer ya29.test", "x-goog-upload-protocol": "raw", "x-goog-upload-file-name": "app.apk", "content-type": "application/octet-stream" });
    expect(new TextDecoder().decode(upload.body as Uint8Array)).toBe("apk-bytes");
    expect(JSON.parse(String(calls[3].body))).toEqual({ name: `projects/${PROJECT_NUMBER}/apps/${APP_ID_ANDROID}/releases/rel-android`, releaseNotes: { text: "sample 1.0.0 (uat) deployment 77" } });
    expect(JSON.parse(String(calls[4].body))).toEqual({ testerEmails: [], groupAliases: ["internal"] });
    expect(summary).toMatchObject({
      provider: "firebase",
      project: FIREBASE_PROJECT,
      group: "internal",
      rollout_percentage: 100,
      releases: {
        android: { app_id: APP_ID_ANDROID, name: `projects/${PROJECT_NUMBER}/apps/${APP_ID_ANDROID}/releases/rel-android`, group: "internal", version: "1.0.0", build: "10", result: "RELEASE_CREATED" },
        ios: { app_id: APP_ID_IOS, name: `projects/${PROJECT_NUMBER}/apps/${APP_ID_IOS}/releases/rel-ios` },
      },
    });
    expect(summary.partial).toBeUndefined();
  });
  test("a platform failing after another was distributed leaves a partial summary: what reached the group cannot be taken back", async () => {
    const fb = await setup();
    let n = 0;
    h.http.routes.push((url, init) => {
      if (url.endsWith(":distribute") && (init.method ?? "GET") === "POST" && ++n === 2) {
        return new Response(JSON.stringify({ error: { status: "INVALID_ARGUMENT", message: "group alias not found" } }), { status: 400 });
      }
      return undefined;
    });
    const summary = newSummary(fb, "internal");
    await failsWith(distributeAll(log, step, fb, signed(), "internal", summary, { releaseNotes: "n" }), "FIREBASE_GROUP_INVALID", /tester group alias must exist/);
    expect(summary.partial).toBe(true);
    expect(summary.failed).toEqual(["ios"]);
    expect(Object.keys(summary.releases)).toEqual(["android"]);
  });
  test("Firebase's answers become errors that say what to do", async () => {
    const fb = await setup(["android"]);
    const one = [signed()[0]];
    for (const [status, code, hint] of [
      [401, "FIREBASE_UNAUTHENTICATED", /create a new JSON key/],
      [403, "FIREBASE_FORBIDDEN", /Firebase App Distribution Admin role/],
      [404, "FIREBASE_APP_NOT_FOUND", /does not exist in the Firebase project/],
      [503, "FIREBASE_UNAVAILABLE", /unavailable/],
    ] as const) {
      h.firebase.uploadStatus = status;
      await failsWith(distributeAll(log, step, fb, one, "internal", newSummary(fb, "internal"), { releaseNotes: "n" }), code, hint);
    }
    h.firebase.uploadStatus = 200;
    h.http.routes.push((url) => (/operations\/op-android$/.test(url) ? new Response(JSON.stringify({ done: true, error: { status: "INVALID_ARGUMENT", message: "The APK is not signed" } }), { status: 200 }) : undefined));
    await failsWith(distributeAll(log, step, fb, one, "internal", newSummary(fb, "internal"), { releaseNotes: "n" }), "FIREBASE_DISTRIBUTE_FAILED", /could not process .*The APK is not signed/);
  });
});

describe("listing the releases", () => {
  test("maps the App Distribution API's releases of every platform's app, in the console's shape", async () => {
    const fb = await setupFirebase(log, step, configuration() as any, ["android", "ios"], opts);
    h.firebase.releases[APP_ID_ANDROID] = [
      { name: `projects/${PROJECT_NUMBER}/apps/${APP_ID_ANDROID}/releases/0abc`, displayVersion: "1.0.0", buildVersion: "10", createTime: "2025-12-22T18:30:00Z", releaseNotes: { text: "sample 1.0.0 (uat) deployment 77" }, firebaseConsoleUri: "https://console/0abc", testingUri: "https://testing/0abc" },
      { name: `projects/${PROJECT_NUMBER}/apps/${APP_ID_ANDROID}/releases/0abb`, displayVersion: "0.9.0", buildVersion: "9", createTime: "2025-12-20T10:00:00Z" },
    ];
    const results = await listReleases(fb, fb.account, ["android", "ios"]);
    expect(results).toEqual([
      { platform: "android", app_id: APP_ID_ANDROID, release: `projects/${PROJECT_NUMBER}/apps/${APP_ID_ANDROID}/releases/0abc`, version: "1.0.0", build: "10", created_at: "2025-12-22T18:30:00Z", release_notes: "sample 1.0.0 (uat) deployment 77", console_url: "https://console/0abc", testing_url: "https://testing/0abc" },
      { platform: "android", app_id: APP_ID_ANDROID, release: `projects/${PROJECT_NUMBER}/apps/${APP_ID_ANDROID}/releases/0abb`, version: "0.9.0", build: "9", created_at: "2025-12-20T10:00:00Z", release_notes: null, console_url: null, testing_url: null },
    ]);
    const listing = h.http.calls.filter((c) => c.url.includes("/releases?pageSize="));
    expect(listing.map((c) => c.url)).toEqual([
      `https://firebaseappdistribution.googleapis.com/v1/projects/${PROJECT_NUMBER}/apps/${APP_ID_ANDROID}/releases?pageSize=20`,
      `https://firebaseappdistribution.googleapis.com/v1/projects/${PROJECT_NUMBER}/apps/${APP_ID_IOS}/releases?pageSize=20`,
    ]);
    expect(listing[0].headers.authorization).toBe("Bearer ya29.test");
  });
  test("a refusal names the role the service account needs", async () => {
    const fb = await setupFirebase(log, step, configuration() as any, ["android"], opts);
    h.http.routes.push((url) => (url.includes("/releases?pageSize=") ? new Response("{}", { status: 403 }) : undefined));
    await failsWith(listReleases(fb, fb.account, ["android"]), "FIREBASE_LIST_FAILED", /Firebase App Distribution Viewer role/);
  });
});
