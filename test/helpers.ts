/**
 * The seams every test replaces, in one harness: a CLI that records argv and
 * answers from a table (apksigner), AWS that answers from maps (STS, S3,
 * Secrets Manager), an HTTP router for Google's token endpoint and the App
 * Distribution API, a platform that answers from fixtures, and a private
 * scratch directory. Plus the fixtures: APK/IPA zips, a service account with
 * a freshly generated key (never a real one), the scope configuration.
 */
import { afterEach, beforeEach } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { deps } from "../src/deps";
import type { ServiceAccount } from "../src/layers/distribution/firebase/index";
import type { ActionContext, AssetRecord, DeploymentRecord, ReleaseRecord, ScopeRecord } from "../src/platform/api";
import type { CliOptions, CliResult } from "../src/support/cli";

process.env.NO_COLOR = "1";

// ─── Fixtures ─────────────────────────────────────────────────────────

export const APP = { id: "442353687", slug: "sample" };
export const BUCKET = "assets-aws-mobile";
export const REGION = "us-east-1";
export const FIREBASE_PROJECT = "np-mobile-pc";
export const PROJECT_NUMBER = "726762523137";
export const APP_ID_ANDROID = `1:${PROJECT_NUMBER}:android:a700b1fa49f91e41eb0e00`;
export const APP_ID_IOS = `1:${PROJECT_NUMBER}:ios:0a1b2c3d4e5f60718293a4b5`;
export const ROLE_ARN = "arn:aws:iam::123456789012:role/nullplatform_test_mobile_store_role";
export const SA_SECRET = "mobile/firebase-sa";
export const KEYSTORE_SECRET = "mobile/android-keystore";
export const APK_URL = `s3://${BUCKET}/mobile/${APP.id}/10/uat/app-release.apk`;
export const IPA_URL = `s3://${BUCKET}/mobile/${APP.id}/10/uat/app.ipa`;
export const PREVIOUS_APK_URL = `s3://${BUCKET}/mobile/${APP.id}/9/uat/app-release.apk`;
export const PREVIOUS_IPA_URL = `s3://${BUCKET}/mobile/${APP.id}/9/uat/app.ipa`;

export const configuration = () => ({
  signing_layer: "prebuilt",
  distribution_layer: "firebase",
  gate_layer: "none",
  firebase: { project: FIREBASE_PROJECT, app_id_android: APP_ID_ANDROID, app_id_ios: APP_ID_IOS, credentials_secret: SA_SECRET },
  android: { package: "ar.io.nullplatform.sample", keystore_secret: KEYSTORE_SECRET },
  assets: { bucket: BUCKET, region: REGION },
});
export const iam = () => ({ iam_role_arns: { arns: [{ selector: "mobile-store", arn: ROLE_ARN }] } });
export const providers = (cfg: Record<string, unknown> = configuration()) => ({
  "scope-configurations": cfg,
  "identity-access-control": iam(),
});

/** The scope as the notification carries it: its dimensions pick the configuration, its asset name the binaries. */
export const scope = { id: "7", slug: "store", dimensions: { environment: "uat" }, asset_name: "android" };
export const service = (attributes: Record<string, unknown> = {}) => ({
  id: "svc-7",
  slug: "store",
  nrn: `organization=1:account=2:namespace=3:application=${APP.id}:scope=7`,
  attributes: { platform: "android", channel: "internal", rollout_percentage: 5, ...attributes },
});
export const deployment = { scope_id: "7", deployment_id: "77" };
/** The run context most tests share. */
export const given = (attributes: Record<string, unknown> = {}, over: Record<string, unknown> = {}) => ({
  scope,
  service: service(attributes),
  providers: providers(),
  ...over,
});

// ─── A zip writer, enough for fixtures (stored entries) ───────────────

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();
const crc32 = (bytes: Uint8Array): number => {
  let c = 0xffffffff;
  for (const b of bytes) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};

export function zipOf(entries: Record<string, string>): Uint8Array {
  const enc = new TextEncoder();
  const parts: Uint8Array[] = [];
  const central: Uint8Array[] = [];
  let offset = 0;
  for (const [name, content] of Object.entries(entries)) {
    const nameBytes = enc.encode(name);
    const data = enc.encode(content);
    const crc = crc32(data);
    const local = new Uint8Array(30 + nameBytes.length);
    const lv = new DataView(local.buffer);
    lv.setUint32(0, 0x04034b50, true);
    lv.setUint16(4, 20, true);
    lv.setUint16(8, 0, true);
    lv.setUint32(14, crc, true);
    lv.setUint32(18, data.length, true);
    lv.setUint32(22, data.length, true);
    lv.setUint16(26, nameBytes.length, true);
    local.set(nameBytes, 30);
    const header = new Uint8Array(46 + nameBytes.length);
    const hv = new DataView(header.buffer);
    hv.setUint32(0, 0x02014b50, true);
    hv.setUint16(4, 20, true);
    hv.setUint16(6, 20, true);
    hv.setUint32(16, crc, true);
    hv.setUint32(20, data.length, true);
    hv.setUint32(24, data.length, true);
    hv.setUint16(28, nameBytes.length, true);
    hv.setUint32(42, offset, true);
    header.set(nameBytes, 46);
    parts.push(local, data);
    central.push(header);
    offset += local.length + data.length;
  }
  const cdSize = central.reduce((n, c) => n + c.length, 0);
  const eocd = new Uint8Array(22);
  const ev = new DataView(eocd.buffer);
  ev.setUint32(0, 0x06054b50, true);
  ev.setUint16(8, central.length, true);
  ev.setUint16(10, central.length, true);
  ev.setUint32(12, cdSize, true);
  ev.setUint32(16, offset, true);
  const all = [...parts, ...central, eocd];
  const out = new Uint8Array(all.reduce((n, p) => n + p.length, 0));
  let p = 0;
  for (const part of all) {
    out.set(part, p);
    p += part.length;
  }
  return out;
}

export const apk = () => zipOf({ "AndroidManifest.xml": "", "classes.dex": "dex" });
export const ipa = () => zipOf({ "Payload/Sample.app/Info.plist": "<plist/>", "Payload/Sample.app/Sample": "bin" });
export const plainZip = () => zipOf({ "readme.txt": "not a mobile binary" });

// ─── A service account with a fresh key (never a real one) ────────────

const KEY = generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey.export({ type: "pkcs8", format: "pem" }) as string;
export const serviceAccount = (): ServiceAccount & { type: string } => ({
  type: "service_account",
  project_id: FIREBASE_PROJECT,
  private_key: KEY,
  client_email: `distributor@${FIREBASE_PROJECT}.iam.gserviceaccount.com`,
  token_uri: "https://oauth2.googleapis.com/token",
});
export const keystoreSecret = () =>
  JSON.stringify({
    keystore_base64: Buffer.from("jks-bytes").toString("base64"),
    keystore_password: "k3yst0re-s3cret",
    key_alias: "release",
    key_password: "k3y-s3cret",
  });

// ─── The harness ──────────────────────────────────────────────────────

export interface HttpCall {
  url: string;
  method: string;
  headers: Record<string, string>;
  body?: string | Uint8Array;
}

export interface FirebaseFake {
  /** The release each app's upload ends in; by platform. */
  releaseOf: (appId: string, platform: string) => Record<string, unknown>;
  uploadStatus: number;
  distributeStatus: number;
  distributeError?: { status: string; message: string };
  /** How many polls answer "not done" before the operation completes. */
  pollsBeforeDone: number;
  /** What the releases listing answers, by app id. */
  releases: Record<string, Array<Record<string, unknown>>>;
  tokenStatus: number;
}

export interface Harness {
  dir: string;
  cli: { calls: Array<{ bin: string; args: string[]; env?: Record<string, string> }>; answers: Record<string, (args: string[]) => Partial<CliResult>> };
  aws: { assumed: Array<{ arn: string; session: string; region: string }>; objects: Record<string, Uint8Array>; secrets: Record<string, string>; s3Error?: string; stsError?: string };
  http: { calls: HttpCall[]; routes: Array<(url: string, init: RequestInit) => Response | undefined> };
  firebase: FirebaseFake;
  platform: {
    entities: ActionContext;
    scopes: Record<string, ScopeRecord>;
    patched: Array<{ id: string; body: Record<string, unknown> }>;
    deployments: DeploymentRecord[];
    releases: ReleaseRecord[];
    assets: Record<string, AssetRecord[]>;
    messages: Array<{ deploymentId: string; level: string; code: string; message: string }>;
    messagesOk: boolean;
    fail: Partial<Record<"scope" | "patch" | "deployments" | "releases" | "release" | "assets", string>>;
  };
}

const headersOf = (init: RequestInit): Record<string, string> => {
  const out: Record<string, string> = {};
  const h = init.headers;
  if (!h) return out;
  if (h instanceof Headers) h.forEach((v, k) => (out[k.toLowerCase()] = v));
  else if (Array.isArray(h)) for (const [k, v] of h) out[k.toLowerCase()] = v;
  else for (const [k, v] of Object.entries(h)) out[k.toLowerCase()] = v as string;
  return out;
};
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

export function harness(): Harness {
  const real = { ...deps };
  const h = {} as Harness;
  beforeEach(async () => {
    h.dir = await mkdtemp(join(tmpdir(), "mobile-store-test-"));
    h.cli = { calls: [], answers: {} };
    h.aws = {
      assumed: [],
      objects: { [APK_URL]: apk(), [IPA_URL]: ipa(), [PREVIOUS_APK_URL]: apk(), [PREVIOUS_IPA_URL]: ipa() },
      secrets: { [SA_SECRET]: JSON.stringify(serviceAccount()), [KEYSTORE_SECRET]: keystoreSecret() },
    };
    h.firebase = {
      releaseOf: (appId, platform) => ({
        name: `projects/${PROJECT_NUMBER}/apps/${appId}/releases/rel-${platform}`,
        displayVersion: "1.0.0",
        buildVersion: "10",
        createTime: "2025-12-22T18:30:00Z",
        firebaseConsoleUri: `https://console.firebase.google.com/project/${FIREBASE_PROJECT}/appdistribution/app/${appId}/releases/rel-${platform}`,
        testingUri: `https://appdistribution.firebase.google.com/testerapps/${appId}/releases/rel-${platform}`,
      }),
      uploadStatus: 200,
      distributeStatus: 200,
      pollsBeforeDone: 0,
      releases: {},
      tokenStatus: 200,
    };
    h.http = { calls: [], routes: [] };
    h.platform = {
      entities: {
        application: APP,
        namespace: { slug: "mobile" },
        scope: { id: "7", slug: "store", asset_name: "android", dimensions: { environment: "uat" } },
        deployment: { id: "77", status: "creating", status_in_scope: "candidate", release_id: "9", created_at: "2025-12-22T18:27:54Z" },
        release: { id: "9", semver: "1.0.0", build_id: "10" },
      },
      scopes: { "7": { id: "7", slug: "store", asset_name: "android", dimensions: { environment: "uat" } } },
      patched: [],
      deployments: [
        { id: "77", status: "creating", status_in_scope: "candidate", release_id: "9", created_at: "2025-12-22T18:27:54Z" },
        { id: "70", status: "finalized", status_in_scope: "active", release_id: "8", created_at: "2025-12-20T10:00:00Z" },
        { id: "65", status: "failed", status_in_scope: "inactive", release_id: "7", created_at: "2025-12-19T10:00:00Z" },
      ],
      releases: [
        { id: "9", semver: "1.0.0", build_id: "10", application_id: APP.id },
        { id: "8", semver: "0.9.0", build_id: "9", application_id: APP.id },
      ],
      assets: {
        "10": [
          { id: "6", name: "android", type: "bundle", url: APK_URL, build_id: "10" },
          { id: "7", name: "ios", type: "bundle", url: IPA_URL, build_id: "10" },
          { id: "8", name: "android", type: "docker-image", url: "registry/app:10", build_id: "10" },
        ],
        "9": [
          { id: "4", name: "android", type: "bundle", url: PREVIOUS_APK_URL, build_id: "9" },
          { id: "5", name: "ios", type: "bundle", url: PREVIOUS_IPA_URL, build_id: "9" },
        ],
      },
      messages: [],
      messagesOk: true,
      fail: {},
    };

    deps.env = { MOBILE_STORE_WORKDIR: h.dir };
    deps.run = async (bin, args, opts: CliOptions = {}) => {
      h.cli.calls.push({ bin, args, env: opts.env });
      const a = h.cli.answers[bin]?.(args) ?? {};
      for (const line of (a.stdout ?? "").split("\n")) if (line) opts.onLine?.(line, "stdout");
      for (const line of (a.stderr ?? "").split("\n")) if (line) opts.onLine?.(line, "stderr");
      return { bin, args, stdout: a.stdout ?? "", stderr: a.stderr ?? "", exitCode: a.exitCode ?? 0 };
    };
    deps.aws = {
      assumeRole: async (arn, session, region) => {
        if (h.aws.stsError) throw new Error(h.aws.stsError);
        h.aws.assumed.push({ arn, session, region });
        return { accessKeyId: "ASIA_TEST", secretAccessKey: "secret", sessionToken: `token-for-${arn.split("/").pop()}` };
      },
      getObject: async (bucket, key) => {
        if (h.aws.s3Error) throw new Error(h.aws.s3Error);
        const found = h.aws.objects[`s3://${bucket}/${key}`];
        if (!found) throw new Error(`NoSuchKey: s3://${bucket}/${key}`);
        return found;
      },
      getSecret: async (name) => {
        const found = h.aws.secrets[name];
        if (found === undefined) throw new Error(`ResourceNotFoundException: ${name}`);
        return found;
      },
    };
    deps.fetch = async (input, init = {}) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
      const method = (init.method ?? "GET").toUpperCase();
      const body = init.body as string | URLSearchParams | Uint8Array | undefined;
      h.http.calls.push({ url, method, headers: headersOf(init), body: body instanceof URLSearchParams ? body.toString() : body });
      for (const route of h.http.routes) {
        const res = route(url, init);
        if (res) return res;
      }
      return defaultRoute(h, url, method);
    };
    deps.platform = {
      context: async () => h.platform.entities,
      scope: async (_ctx, id) => {
        if (h.platform.fail.scope) throw new Error(h.platform.fail.scope);
        const s = h.platform.scopes[id];
        if (!s) throw new Error(`no scope ${id}`);
        return s;
      },
      patchScope: async (_ctx, id, body) => {
        if (h.platform.fail.patch) throw new Error(h.platform.fail.patch);
        h.platform.patched.push({ id, body });
        h.platform.scopes[id] = { ...(h.platform.scopes[id] ?? { id }), ...body } as ScopeRecord;
      },
      deployments: async () => {
        if (h.platform.fail.deployments) throw new Error(h.platform.fail.deployments);
        return h.platform.deployments;
      },
      release: async (_ctx, id) => {
        if (h.platform.fail.release) throw new Error(h.platform.fail.release);
        const r = h.platform.releases.find((x) => x.id === id);
        if (!r) throw new Error(`no release ${id}`);
        return r;
      },
      releases: async () => {
        if (h.platform.fail.releases) throw new Error(h.platform.fail.releases);
        return h.platform.releases;
      },
      assets: async (_ctx, buildId) => {
        if (h.platform.fail.assets) throw new Error(h.platform.fail.assets);
        return h.platform.assets[buildId] ?? [];
      },
      message: async (_ctx, deploymentId, level, code, message) => {
        h.platform.messages.push({ deploymentId, level, code, message });
        return h.platform.messagesOk;
      },
    };
  });
  afterEach(async () => {
    Object.assign(deps, real);
    await rm(h.dir, { recursive: true, force: true });
  });
  return h;
}

const polls = new Map<string, number>();

/** Google's token endpoint, the App Distribution API and the assets bucket over https, as the fakes answer them. */
function defaultRoute(h: Harness, url: string, method: string): Response {
  if (url === "https://oauth2.googleapis.com/token") {
    return h.firebase.tokenStatus === 200 ? json(200, { access_token: "ya29.test", expires_in: 3600 }) : json(h.firebase.tokenStatus, { error: "invalid_grant" });
  }
  const upload = url.match(/\/upload\/v1\/projects\/(\d+)\/apps\/([^/]+)\/releases:upload$/);
  if (upload && method === "POST") {
    if (h.firebase.uploadStatus !== 200) return json(h.firebase.uploadStatus, { error: { status: "FAILED", message: `upload refused with ${h.firebase.uploadStatus}` } });
    polls.set(upload[2], 0);
    return json(200, { name: `projects/${upload[1]}/apps/${upload[2]}/operations/op-${upload[2].split(":")[2]}` });
  }
  const operation = url.match(/\/v1\/projects\/\d+\/apps\/([^/]+)\/operations\/op-(\w+)$/);
  if (operation && method === "GET") {
    const n = (polls.get(operation[1]) ?? 0) + 1;
    polls.set(operation[1], n);
    if (n <= h.firebase.pollsBeforeDone) return json(200, { name: url.split("/v1/")[1], done: false });
    return json(200, { done: true, response: { result: "RELEASE_CREATED", release: h.firebase.releaseOf(operation[1], operation[2]) } });
  }
  if (/\/v1\/projects\/\d+\/apps\/[^/]+\/releases\/[^/?]+\?updateMask=release_notes\.text$/.test(url) && method === "PATCH") return json(200, {});
  if (/\/v1\/projects\/\d+\/apps\/[^/]+\/releases\/[^/:]+:distribute$/.test(url) && method === "POST") {
    if (h.firebase.distributeStatus !== 200) {
      return json(h.firebase.distributeStatus, { error: h.firebase.distributeError ?? { status: "INTERNAL", message: `distribute refused with ${h.firebase.distributeStatus}` } });
    }
    return json(200, {});
  }
  const listing = url.match(/\/v1\/projects\/\d+\/apps\/([^/]+)\/releases\?pageSize=\d+$/);
  if (listing && method === "GET") return json(200, { releases: h.firebase.releases[listing[1]] ?? [] });
  const https = url.match(/^https:\/\/([a-z0-9.-]+)\.s3(?:\.[a-z0-9-]+)?\.amazonaws\.com\/(.+)$/);
  if (https) {
    const found = h.aws.objects[`s3://${https[1]}/${https[2]}`];
    return found ? new Response(found.slice() as unknown as BodyInit, { status: 200 }) : new Response("not found", { status: 404 });
  }
  return new Response(`no fake route for ${method} ${url}`, { status: 599 });
}

/** The messages the scope recorded on a deployment, by code, their JSON payload parsed. */
export function recorded(h: Harness, code: string): Array<Record<string, unknown>> {
  return h.platform.messages
    .filter((m) => m.code === code)
    .map((m) => {
      const brace = m.message.indexOf("{");
      return brace === -1 ? { text: m.message } : (JSON.parse(m.message.slice(brace)) as Record<string, unknown>);
    });
}

// ─── Assertions ───────────────────────────────────────────────────────

/** Expects a rejection (or a throw, when given a function) that is an ActionError with `code`, and a message matching `pattern` when given. */
export async function failsWith(subject: Promise<unknown> | (() => unknown), code: string, pattern?: RegExp): Promise<void> {
  let caught: unknown;
  try {
    await (typeof subject === "function" ? Promise.resolve().then(subject) : subject);
  } catch (err) {
    caught = err;
  }
  if (!caught) throw new Error(`expected a failure with code ${code}, but it succeeded`);
  const e = caught as { code?: string; message?: string };
  if (e.code !== code) throw new Error(`expected code ${code}, got ${e.code ?? "(none)"}: ${e.message}`);
  if (pattern && !pattern.test(e.message ?? "")) throw new Error(`expected the message to match ${pattern}: ${e.message}`);
}

/** A handler context with a silent log, for a layer called directly. */
export const quiet = { log: { detail() {}, ok() {}, step() {}, fail() {} } } as any;
export const silentStep = { explain() {}, link() {}, output() {} };
