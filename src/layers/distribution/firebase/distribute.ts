/**
 * Publish and rollback on Firebase App Distribution, through its REST API —
 * the four calls the firebase CLI makes for `appdistribution:distribute`:
 *
 *   1. POST /upload/v1/{app}/releases:upload      the binary, raw; answers an operation
 *   2. GET  /v1/{operation}                        polled until done; answers the release
 *   3. PATCH /v1/{release}?updateMask=release_notes.text   the release notes
 *   4. POST /v1/{release}:distribute               to the group named by the channel
 *
 * Firebase has no staged rollout, so the effective rollout is always 100%,
 * and it cannot unpublish: a rollback distributes the previous release again
 * so it becomes the group's latest build. When a platform fails after
 * another was distributed, the summary says so (`partial`): what reached the
 * group cannot be taken back.
 */

import { basename } from "node:path";
import { ActionError, type Narrative } from "@nullplatform/plugin/package";
import { deps } from "../../../deps";
import type { Channel, Context, Platform } from "../../../scope/schema";
import type { Signed } from "../../signing/index";
import { apiOrigin, appName, consoleUrl, LAYER, type FirebaseSetup } from "./index";
import { accessToken } from "./token";

export interface DistributedRelease {
  app_id: string;
  /** projects/<n>/apps/<app id>/releases/<id> */
  name: string | null;
  group: string;
  version?: string;
  build?: string;
  /** Whether the upload created a new release, updated one, or found this exact binary already there. */
  result?: string;
  console_url?: string;
  testing_url?: string;
}

/** The distribution summary: what the scope records on the deployment. */
export interface DistributionSummary {
  provider: typeof LAYER;
  project: string;
  group: string;
  channel: Channel;
  rollout_percentage: 100;
  releases: Partial<Record<Platform, DistributedRelease>>;
  rollback_to?: string;
  partial?: true;
  failed?: Platform[];
}

export const newSummary = (fb: FirebaseSetup, channel: Channel, extra: Partial<DistributionSummary> = {}): DistributionSummary => ({
  provider: LAYER,
  project: fb.project,
  group: channel,
  channel,
  rollout_percentage: 100,
  releases: {},
  ...extra,
});

interface ApiRelease {
  name?: string;
  displayVersion?: string;
  buildVersion?: string;
  createTime?: string;
  firebaseConsoleUri?: string;
  testingUri?: string;
}

interface Operation {
  name?: string;
  done?: boolean;
  error?: { code?: number; message?: string; status?: string };
  response?: { result?: string; release?: ApiRelease };
}

export interface DistributeOptions {
  releaseNotes: string;
  signal?: AbortSignal;
  /** How long to wait for the upload to be processed (the CLI waits 5 minutes). */
  uploadTimeoutMs?: number;
  /** The first wait between polls; doubles up to ten times that. */
  pollMs?: number;
}

const sleep = (ms: number, signal?: AbortSignal) =>
  new Promise<void>((resolve, reject) => {
    const t = setTimeout(resolve, ms);
    signal?.addEventListener("abort", () => (clearTimeout(t), reject(new ActionError("CANCELLED", "cancelled"))), { once: true });
  });

async function said(res: Response): Promise<string> {
  const text = await res.text().catch(() => "");
  try {
    const json = JSON.parse(text) as { error?: { message?: string; status?: string } };
    const e = json.error;
    if (e?.message) return `${e.status ? `${e.status}: ` : ""}${e.message}`.slice(0, 400);
  } catch {
    // not JSON
  }
  return text.trim().slice(0, 400);
}

/** The error a Firebase answer means, with what to do about it. */
async function failureFor(res: Response, platform: Platform, what: string, fb: FirebaseSetup, appId: string): Promise<ActionError> {
  const detail = await said(res);
  const where = `${platform}: Firebase App Distribution ${what} (HTTP ${res.status}${detail ? `: ${detail}` : ""})`;
  if (res.status === 401) {
    return new ActionError(
      "FIREBASE_UNAUTHENTICATED",
      `${where}. The key of the service account expired, was deleted or was revoked: create a new JSON key and store it in secret '${fb.secretName}'`,
    );
  }
  if (res.status === 403) {
    return new ActionError(
      "FIREBASE_FORBIDDEN",
      `${where}. Grant the service account in secret '${fb.secretName}' the Firebase App Distribution Admin role on project '${fb.project}'`,
    );
  }
  if (res.status === 404) {
    return new ActionError(
      "FIREBASE_APP_NOT_FOUND",
      `${where}. The app id '${appId}' does not exist in the Firebase project '${fb.project}': copy the ${platform} app id from the Firebase console (Project settings > Your apps) into firebase.app_id_${platform}`,
    );
  }
  if (res.status === 400 && /INVALID_ARGUMENT|group/i.test(detail)) {
    return new ActionError(
      "FIREBASE_GROUP_INVALID",
      `${where}. The tester group alias must exist in project '${fb.project}': create a group whose alias is the developer's channel (internal, testers or production) in the Firebase console, App Distribution > Testers & Groups`,
    );
  }
  if (res.status >= 500 || res.status === 429) {
    return ActionError.retry("FIREBASE_UNAVAILABLE", `${where}. Firebase App Distribution is unavailable; retry the deployment`);
  }
  return new ActionError("FIREBASE_DISTRIBUTE_FAILED", `${where}. Run the firebase CLI with the service account to see the full error`);
}

async function call(url: string, init: RequestInit & { signal?: AbortSignal }, token: string): Promise<Response> {
  try {
    return await deps.fetch(url, {
      ...init,
      headers: { authorization: `Bearer ${token}`, ...((init.headers as Record<string, string> | undefined) ?? {}) },
      signal: init.signal ?? AbortSignal.timeout(120_000),
    });
  } catch (err) {
    if (err instanceof ActionError) throw err;
    throw ActionError.retry("FIREBASE_UNAVAILABLE", `could not reach ${url}: ${err instanceof Error ? err.message : String(err)}`);
  }
}

/** Uploads one binary to its Firebase app, sets the release notes and distributes it to the channel's group. */
export async function distribute(
  ctx: Pick<Context, "log">,
  fb: FirebaseSetup,
  token: string,
  binary: Signed,
  channel: Channel,
  opts: DistributeOptions,
): Promise<DistributedRelease> {
  const appId = fb.appIds[binary.platform];
  if (!appId) throw new ActionError("CONFIGURATION_INCOMPLETE", `the Firebase setup has no app id for ${binary.platform}`);
  const origin = apiOrigin();
  const app = appName(appId);
  const platform = binary.platform;

  // 1. Upload the binary: the API answers a long-running operation.
  ctx.log.detail(`${platform}: uploading ${binary.signedPath} to Firebase app ${appId}`);
  const bytes = new Uint8Array(await Bun.file(binary.signedPath).arrayBuffer());
  const uploaded = await call(
    `${origin}/upload/v1/${app}/releases:upload`,
    {
      method: "POST",
      headers: {
        "X-Goog-Upload-File-Name": encodeURIComponent(basename(binary.signedPath)),
        "X-Goog-Upload-Protocol": "raw",
        "Content-Type": "application/octet-stream",
      },
      body: bytes,
      signal: opts.signal,
    },
    token,
  );
  if (!uploaded.ok) throw await failureFor(uploaded, platform, `rejected the upload of ${binary.signedPath}`, fb, appId);
  const operation = ((await uploaded.json().catch(() => ({}))) as Operation).name;
  if (!operation) throw new ActionError("FIREBASE_DISTRIBUTE_FAILED", `${platform}: the upload answered without an operation name`);

  // 2. Wait for Firebase to process it: the operation answers the release when done.
  const deadline = Date.now() + (opts.uploadTimeoutMs ?? 5 * 60_000);
  let wait = opts.pollMs ?? 1000;
  let release: ApiRelease | undefined;
  let result: string | undefined;
  for (;;) {
    const polled = await call(`${origin}/v1/${operation}`, { method: "GET", signal: opts.signal }, token);
    if (!polled.ok) throw await failureFor(polled, platform, `did not report the upload of ${binary.signedPath}`, fb, appId);
    const op = (await polled.json().catch(() => ({}))) as Operation;
    if (op.done) {
      if (op.error) {
        throw new ActionError(
          "FIREBASE_DISTRIBUTE_FAILED",
          `${platform}: Firebase App Distribution could not process ${binary.signedPath}: ${op.error.status ? `${op.error.status}: ` : ""}${op.error.message ?? "unknown error"}. Make sure the binary is the signed ${platform === "android" ? "APK/AAB" : "IPA"} of the app registered as ${appId}`,
        );
      }
      release = op.response?.release;
      result = op.response?.result;
      break;
    }
    if (Date.now() > deadline) {
      throw ActionError.retry(
        "FIREBASE_UPLOAD_TIMEOUT",
        `${platform}: Firebase App Distribution did not finish processing ${binary.signedPath} in time (operation ${operation}); retry the deployment`,
      );
    }
    await sleep(Math.min(wait, (opts.pollMs ?? 1000) * 10), opts.signal);
    wait *= 2;
  }
  const name = release?.name ?? null;
  if (!name) throw new ActionError("FIREBASE_DISTRIBUTE_FAILED", `${platform}: the upload finished but Firebase named no release`);
  ctx.log.detail(`${platform}: release ${name} (${result ?? "uploaded"}${release?.displayVersion ? `, version ${release.displayVersion}` : ""}${release?.buildVersion ? ` build ${release.buildVersion}` : ""})`);

  // 3. The release notes: what the testers read.
  if (opts.releaseNotes.trim()) {
    const noted = await call(
      `${origin}/v1/${name}?updateMask=release_notes.text`,
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name, releaseNotes: { text: opts.releaseNotes } }),
        signal: opts.signal,
      },
      token,
    );
    if (!noted.ok) ctx.log.detail(`${platform}: the release notes were not set (HTTP ${noted.status}); the release is distributed without them`);
  }

  // 4. Distribute to the group the channel names.
  const distributed = await call(
    `${origin}/v1/${name}:distribute`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ testerEmails: [], groupAliases: [channel] }),
      signal: opts.signal,
    },
    token,
  );
  if (!distributed.ok) throw await failureFor(distributed, platform, `did not distribute release ${name} to group '${channel}'`, fb, appId);
  ctx.log.detail(`${platform}: distributed to Firebase group '${channel}'`);
  return {
    app_id: appId,
    name,
    group: channel,
    ...(release?.displayVersion ? { version: release.displayVersion } : {}),
    ...(release?.buildVersion ? { build: release.buildVersion } : {}),
    ...(result ? { result } : {}),
    console_url: release?.firebaseConsoleUri ?? consoleUrl(fb.project, appId),
    ...(release?.testingUri ? { testing_url: release.testingUri } : {}),
  };
}

/**
 * Distributes every binary, in order, into `summary`. On a failure after
 * another platform was distributed the summary is marked partial and the
 * error rethrown: those releases cannot be taken back.
 */
export async function distributeAll(
  ctx: Pick<Context, "log">,
  step: Narrative,
  fb: FirebaseSetup,
  binaries: Signed[],
  channel: Channel,
  summary: DistributionSummary,
  opts: DistributeOptions,
): Promise<DistributionSummary> {
  const token = await accessToken(fb.account);
  const done: Platform[] = [];
  for (const binary of binaries) {
    try {
      summary.releases[binary.platform] = await distribute(ctx, fb, token, binary, channel, opts);
      done.push(binary.platform);
    } catch (err) {
      if (done.length) {
        summary.partial = true;
        summary.failed = [binary.platform];
        ctx.log.detail(`${done.join(", ")} already distributed to group '${channel}'; ${binary.platform} failed`);
        step.explain({
          severity: "error",
          what: `${done.join(" and ")} reached Firebase group '${channel}' but ${binary.platform} did not: ${err instanceof Error ? err.message : String(err)}`,
          impact: `The ${done.join(" and ")} release${done.length > 1 ? "s" : ""} cannot be taken back from the group; the deployment is recorded as a partial distribution.`,
          next: "Fix the cause and deploy again so every platform of the scope ships the same release.",
        });
      }
      throw err;
    }
  }
  for (const platform of done) {
    const r = summary.releases[platform];
    if (r?.console_url) step.link({ rel: "firebase-console", uri: r.console_url, label: `${platform} release in Firebase` });
    if (r?.testing_url) step.link({ rel: "firebase-testing", uri: r.testing_url, label: `${platform} testing page` });
  }
  step.output("distribution", summary);
  return summary;
}
