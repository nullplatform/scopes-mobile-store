/**
 * The deployment actions end to end, through the SDK's in-process runner:
 * the notification the platform would send, every seam faked, and the
 * worker's own behaviour — steps, logs, messages, traffic — asserted.
 */
import { describe, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { stat } from "node:fs/promises";
import { join } from "node:path";
import { Actions } from "@nullplatform/plugin/package";
import pkg from "../../src/package";
import { target } from "../../src/scope/resources";
import { APK_URL, APP_ID_ANDROID, APP_ID_IOS, configuration, deployment, FIREBASE_PROJECT, given, harness, IPA_URL, PREVIOUS_APK_URL, PROJECT_NUMBER, providers, recorded, ROLE_ARN } from "../helpers";

const h = harness();
const steps = (run: { steps: Array<{ key: string }> }) => run.steps.map((s) => s.key);
const firebaseCalls = () => h.http.calls.filter((c) => c.url.includes("firebaseappdistribution")).map((c) => `${c.method} ${c.url.split(".com")[1]}`);

describe("start-initial", () => {
  test("publishes the android binary of the release to the internal group and records the distribution on the deployment", async () => {
    const run = await pkg.run(target, Actions.START_INITIAL, deployment, given());
    expect(run.error).toBeUndefined();
    expect(run.status).toBe("success");
    expect(steps(run)).toEqual(["resolve context", "assume role", "resolve assets", "download binaries", "sign", "setup distribution", "gate", "publish"]);
    // The scope's role, assumed from the IAM provider for selector mobile-store.
    expect(h.aws.assumed).toEqual([{ arn: ROLE_ARN, session: "np-mobile-store-7", region: "us-east-1" }]);
    // The binary, downloaded into the deployment's scratch directory and checked.
    expect((await stat(join(h.dir, "77", "android", "app.apk"))).isFile()).toBe(true);
    // Firebase: upload → operation → notes → distribute, for the one platform.
    expect(firebaseCalls()).toEqual([
      `POST /upload/v1/projects/${PROJECT_NUMBER}/apps/${APP_ID_ANDROID}/releases:upload`,
      `GET /v1/projects/${PROJECT_NUMBER}/apps/${APP_ID_ANDROID}/operations/op-android`,
      `PATCH /v1/projects/${PROJECT_NUMBER}/apps/${APP_ID_ANDROID}/releases/rel-android?updateMask=release_notes.text`,
      `POST /v1/projects/${PROJECT_NUMBER}/apps/${APP_ID_ANDROID}/releases/rel-android:distribute`,
    ]);
    const notes = h.http.calls.find((c) => c.method === "PATCH")!;
    expect(JSON.parse(String(notes.body)).releaseNotes.text).toBe("sample 1.0.0 (uat) deployment 77");
    // The summary recorded on the deployment, the way the console reads it.
    const [summary] = recorded(h, "MOBILE_STORE_DISTRIBUTION");
    expect(summary).toMatchObject({
      provider: "firebase",
      project: FIREBASE_PROJECT,
      group: "internal",
      channel: "internal",
      rollout_percentage: 100,
      releases: { android: { app_id: APP_ID_ANDROID, name: `projects/${PROJECT_NUMBER}/apps/${APP_ID_ANDROID}/releases/rel-android`, group: "internal" } },
    });
    expect(h.platform.messages[0]).toMatchObject({ deploymentId: "77", level: "INFO", code: "MOBILE_STORE_DISTRIBUTION" });
    expect(run.logs.some((l) => l.includes("asset name android (from the context)"))).toBe(true);
    expect(run.logs.some((l) => l.includes(`android: ${APK_URL}`) || l.includes(`android: android -> ${APK_URL}`))).toBe(true);
  });

  test("a scope with both platforms ships both binaries, ios named from the android asset", async () => {
    const run = await pkg.run(target, Actions.START_INITIAL, deployment, given({ platform: "both", channel: "testers" }));
    expect(run.status).toBe("success");
    expect(h.aws.objects[IPA_URL]).toBeDefined();
    const [summary] = recorded(h, "MOBILE_STORE_DISTRIBUTION");
    expect(Object.keys(summary.releases as object)).toEqual(["android", "ios"]);
    expect((summary.releases as any).ios.app_id).toBe(APP_ID_IOS);
    expect(summary.group).toBe("testers");
    for (const c of h.http.calls.filter((c) => c.url.endsWith(":distribute"))) expect(JSON.parse(String(c.body)).groupAliases).toEqual(["testers"]);
  });

  test("the scope's asset name picks the binaries: android-internal and ios-internal", async () => {
    h.platform.assets["10"] = [
      { id: "1", name: "android-internal", type: "bundle", url: `s3://assets-aws-mobile/i/app.apk`, build_id: "10" },
      { id: "2", name: "ios-internal", type: "bundle", url: `s3://assets-aws-mobile/i/app.ipa`, build_id: "10" },
    ];
    h.aws.objects["s3://assets-aws-mobile/i/app.apk"] = h.aws.objects[APK_URL];
    h.aws.objects["s3://assets-aws-mobile/i/app.ipa"] = h.aws.objects[IPA_URL];
    const run = await pkg.run(target, Actions.START_INITIAL, deployment, given({ platform: "both" }, { scope: { id: "7", slug: "store", dimensions: { environment: "uat" }, asset_name: "android-internal" } }));
    expect(run.error).toBeUndefined();
    expect(run.logs.some((l) => l.includes("asset name android-internal"))).toBe(true);
  });

  test("a release without the named asset fails before anything is downloaded", async () => {
    h.platform.assets["10"] = [];
    const run = await pkg.run(target, Actions.START_INITIAL, deployment, given());
    expect(run.status).toBe("failed");
    expect(run.error).toMatchObject({ code: "NO_ASSET" });
    expect(run.error?.message).toContain("named 'android' of type 'bundle' in release 1.0.0");
    expect(h.http.calls).toHaveLength(0);
  });

  test("a binary that is not an APK fails before signing or publishing, naming what the CI must upload", async () => {
    h.aws.objects[APK_URL] = new TextEncoder().encode("not a zip at all, just text that is long enough to be scanned for a zip end record");
    const run = await pkg.run(target, Actions.START_INITIAL, deployment, given());
    expect(run.error).toMatchObject({ code: "NOT_A_MOBILE_BINARY" });
    expect(run.steps.at(-1)).toMatchObject({ key: "download binaries", status: "failed" });
    expect(firebaseCalls()).toEqual([]);
  });

  test("production on Firebase without a gate publishes with a warning; on a public store it is refused before the binary moves", async () => {
    const ok = await pkg.run(target, Actions.START_INITIAL, deployment, given({ channel: "production" }));
    expect(ok.status).toBe("success");
    expect(ok.logs.some((l) => l.includes("without an external approval gate"))).toBe(true);
    const store = await pkg.run(target, Actions.START_INITIAL, deployment, given({ channel: "production" }, { providers: providers({ ...configuration(), distribution_layer: "app-store" }) }));
    expect(store.error).toMatchObject({ code: "LAYER_NOT_IMPLEMENTED" });
    expect(store.steps).toHaveLength(1);
  });

  test("a scope configuration naming an unimplemented or unknown layer fails at the first step", async () => {
    const match = await pkg.run(target, Actions.START_INITIAL, deployment, given({}, { providers: providers({ ...configuration(), signing_layer: "match" }) }));
    expect(match.error).toMatchObject({ code: "LAYER_NOT_IMPLEMENTED" });
    expect(match.error?.message).toContain("'match' is not implemented yet");
    const none = await pkg.run(target, Actions.START_INITIAL, deployment, given({}, { providers: { "identity-access-control": {} } }));
    expect(none.error).toMatchObject({ code: "CONFIGURATION_INCOMPLETE" });
  });

  test("the keyvault signing layer signs the android binary before it is uploaded", async () => {
    // The fake apksigner writes the signed APK it is asked for, as the real one does.
    h.cli.answers.apksigner = (args) => {
      if (args[0] === "sign") writeFileSync(args[args.indexOf("--out") + 1], "signed-apk");
      return {};
    };
    const run = await pkg.run(target, Actions.START_INITIAL, deployment, given({}, { providers: providers({ ...configuration(), signing_layer: "keyvault" }) }));
    expect(run.error).toBeUndefined();
    expect(h.cli.calls.map((c) => `${c.bin} ${c.args[0]}`)).toEqual(["apksigner sign", "apksigner verify"]);
    const upload = h.http.calls.find((c) => c.url.endsWith(":upload"))!;
    expect(upload.headers["x-goog-upload-file-name"]).toBe("app-signed.apk");
  });

  test("a platform failing after another shipped is recorded as a partial distribution, and the action fails", async () => {
    let n = 0;
    h.http.routes.push((url, init) => (url.endsWith(":distribute") && init.method === "POST" && ++n === 2 ? new Response(JSON.stringify({ error: { status: "INTERNAL", message: "boom" } }), { status: 500 }) : undefined));
    const run = await pkg.run(target, Actions.START_INITIAL, deployment, given({ platform: "both" }));
    expect(run.status).toBe("failed");
    expect(run.error).toMatchObject({ code: "FIREBASE_UNAVAILABLE", retryable: true });
    expect(h.platform.messages.map((m) => m.code)).toEqual(["MOBILE_STORE_DISTRIBUTION_PARTIAL"]);
    expect(recorded(h, "MOBILE_STORE_DISTRIBUTION_PARTIAL")[0]).toMatchObject({ partial: true, failed: ["ios"] });
  });

  test("no role named for the scope means the agent's own credentials; MOBILE_STORE_ASSUME_ROLE_ARN overrides the provider", async () => {
    const agent = await pkg.run(target, Actions.START_INITIAL, deployment, given({}, { providers: { "scope-configurations": configuration() } }));
    expect(agent.status).toBe("success");
    expect(h.aws.assumed).toEqual([]);
    h.aws.assumed.length = 0;
    (await import("../../src/deps")).deps.env.MOBILE_STORE_ASSUME_ROLE_ARN = "arn:aws:iam::1:role/override";
    await pkg.run(target, Actions.START_INITIAL, deployment, given());
    expect(h.aws.assumed[0].arn).toBe("arn:aws:iam::1:role/override");
  });

  test("the deployment message is best effort: a refused patch does not fail the publish", async () => {
    h.platform.messagesOk = false;
    const run = await pkg.run(target, Actions.START_INITIAL, deployment, given());
    expect(run.status).toBe("success");
    expect(run.logs.some((l) => l.includes("could not record MOBILE_STORE_DISTRIBUTION"))).toBe(true);
  });
});

describe("start-blue-green", () => {
  test("is the initial publish once no other deployment of the scope is rolling out", async () => {
    const run = await pkg.run(target, Actions.START_BLUE_GREEN, deployment, given());
    expect(run.status).toBe("success");
    expect(steps(run)[0]).toBe("check active rollout");
    expect(steps(run)).toHaveLength(9);
  });
  test("is refused while another deployment is in progress, and fails closed when the deployments cannot be listed", async () => {
    h.platform.deployments.push({ id: "80", status: "switching_traffic", status_in_scope: "candidate", created_at: "2025-12-23T00:00:00Z" });
    const busy = await pkg.run(target, Actions.START_BLUE_GREEN, deployment, given());
    expect(busy.error).toMatchObject({ code: "ROLLOUT_IN_PROGRESS" });
    expect(busy.error?.message).toContain("deployment 80");
    expect(h.http.calls).toHaveLength(0);
    h.platform.fail.deployments = "503";
    const unknown = await pkg.run(target, Actions.START_BLUE_GREEN, deployment, given());
    expect(unknown.error).toMatchObject({ code: "DEPLOYMENTS_UNLISTABLE", retryable: true });
  });
});

describe("switch-traffic and finalize-blue-green", () => {
  test("acknowledge the weight and record the rollout state: Firebase has no staged rollout", async () => {
    const run = await pkg.run(target, Actions.SWITCH_TRAFFIC, { ...deployment, desired_traffic: 40 }, given());
    expect(run.status).toBe("success");
    expect(steps(run)).toEqual(["resolve context", "record rollout state"]);
    expect(run.traffic).toEqual([40]);
    expect(h.platform.messages[0]).toMatchObject({ code: "MOBILE_STORE_ROLLOUT" });
    expect(h.platform.messages[0].message).toContain("switch_traffic: Firebase App Distribution has no staged rollout: release 1.0.0 is already available to all of group 'internal'");
    expect(h.http.calls).toHaveLength(0);
    const fin = await pkg.run(target, Actions.FINALIZE_BLUE_GREEN, deployment, given());
    expect(fin.status).toBe("success");
    expect(h.platform.messages[1].message).toContain("finalize: Release 1.0.0 stays the latest build of Firebase group 'internal'");
  });
  test("refuse a weight they do not have, and a distribution with a staged rollout nobody implemented yet", async () => {
    const none = await pkg.run(target, Actions.SWITCH_TRAFFIC, deployment, given());
    expect(none.error).toMatchObject({ code: "NO_WEIGHT" });
    const store = await pkg.run(target, Actions.SWITCH_TRAFFIC, { ...deployment, desired_traffic: 10 }, given({}, { providers: providers({ ...configuration(), distribution_layer: "google-play" }) }));
    expect(store.error).toMatchObject({ code: "LAYER_NOT_IMPLEMENTED" });
  });
});

describe("rollback-deployment", () => {
  test("distributes the previous release's binaries again, signed, with rollback release notes", async () => {
    const run = await pkg.run(target, Actions.ROLLBACK_DEPLOYMENT, deployment, given());
    expect(run.error).toBeUndefined();
    expect(steps(run)).toEqual(["resolve context", "assume role", "resolve previous assets", "download binaries", "sign", "setup distribution", "publish"]);
    expect(run.logs.some((l) => l.includes("previous deployment 70 (release 0.9.0)"))).toBe(true);
    expect(run.logs.some((l) => l.includes(`android of release 0.9.0 -> ${PREVIOUS_APK_URL}`))).toBe(true);
    expect((await stat(join(h.dir, "77", "rollback", "android", "app.apk"))).isFile()).toBe(true);
    const notes = h.http.calls.find((c) => c.method === "PATCH")!;
    expect(JSON.parse(String(notes.body)).releaseNotes.text).toBe("sample rollback to 0.9.0 (uat) deployment 77");
    const [summary] = recorded(h, "MOBILE_STORE_ROLLBACK");
    expect(summary).toMatchObject({ provider: "firebase", rollback_to: "0.9.0", group: "internal" });
  });
  test("without a previous finalized deployment there is nothing to roll back to, and Firebase cannot unpublish", async () => {
    h.platform.deployments = h.platform.deployments.filter((d) => d.status !== "finalized");
    const run = await pkg.run(target, Actions.ROLLBACK_DEPLOYMENT, deployment, given());
    expect(run.error).toMatchObject({ code: "NO_PREVIOUS_DEPLOYMENT" });
    expect(run.error?.message).toContain("cannot unpublish");
  });
  test("a previous release whose binaries are gone fails with what to deploy instead", async () => {
    h.platform.assets["9"] = [];
    const run = await pkg.run(target, Actions.ROLLBACK_DEPLOYMENT, deployment, given());
    expect(run.error).toMatchObject({ code: "NO_ASSET" });
    expect(run.error?.message).toContain("release 0.9.0");
  });
});

describe("delete-deployment", () => {
  test("removes the deployment's scratch directory and nothing else; it never fails", async () => {
    await Bun.write(join(h.dir, "77", "android", "app.apk"), "x");
    await Bun.write(join(h.dir, "78", "android", "app.apk"), "y");
    const run = await pkg.run(target, Actions.DELETE_DEPLOYMENT, deployment, given());
    expect(run.status).toBe("success");
    await expect(stat(join(h.dir, "77"))).rejects.toThrow();
    expect((await stat(join(h.dir, "78", "android", "app.apk"))).isFile()).toBe(true);
    expect(run.logs.some((l) => l.includes("cannot unpublish"))).toBe(true);
    const again = await pkg.run(target, Actions.DELETE_DEPLOYMENT, deployment, given());
    expect(again.status).toBe("success");
    expect(again.logs.some((l) => l.includes("no scratch directory to remove"))).toBe(true);
  });
  test("depends on nothing being resolvable: a deployment that failed in its first step is still deletable", async () => {
    const run = await pkg.run(target, Actions.DELETE_DEPLOYMENT, deployment, given({}, { providers: {} }));
    expect(run.status).toBe("success");
  });
});
