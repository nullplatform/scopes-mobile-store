/**
 * instance:data on Firebase App Distribution: the latest releases of the
 * Firebase app of every platform of the scope, through the App Distribution
 * REST API, in the shape the console lists instances with.
 */

import { ActionError } from "@nullplatform/plugin/package";
import { deps } from "../../../deps";
import type { Platform } from "../../../scope/schema";
import { projectNumberOf, type FirebaseSetup, type ServiceAccount } from "./index";
import { accessToken } from "./token";

export interface ReleaseInstance {
  platform: Platform;
  app_id: string;
  /** projects/<n>/apps/<app id>/releases/<id> */
  release: string | null;
  version: string | null;
  build: string | null;
  created_at: string | null;
  release_notes: string | null;
  console_url: string | null;
  testing_url: string | null;
}

interface ApiRelease {
  name?: string;
  displayVersion?: string;
  buildVersion?: string;
  createTime?: string;
  releaseNotes?: { text?: string };
  firebaseConsoleUri?: string;
  testingUri?: string;
}

export const DEFAULT_PAGE_SIZE = 20;

export async function listReleases(
  fb: FirebaseSetup,
  account: ServiceAccount,
  platforms: Platform[],
  pageSize = DEFAULT_PAGE_SIZE,
): Promise<ReleaseInstance[]> {
  const token = await accessToken(account);
  const out: ReleaseInstance[] = [];
  for (const platform of platforms) {
    const appId = fb.appIds[platform];
    if (!appId) throw new ActionError("CONFIGURATION_INCOMPLETE", `the Firebase setup has no app id for ${platform}`);
    const url = `https://firebaseappdistribution.googleapis.com/v1/projects/${projectNumberOf(appId)}/apps/${appId}/releases?pageSize=${pageSize}`;
    let res: Response;
    try {
      res = await deps.fetch(url, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(60_000) });
    } catch (err) {
      throw ActionError.retry("FIREBASE_LIST_FAILED", `could not reach the App Distribution API for the ${platform} app ${appId}: ${err instanceof Error ? err.message : String(err)}`);
    }
    if (!res.ok) {
      throw new ActionError(
        "FIREBASE_LIST_FAILED",
        `could not list the releases of the ${platform} app ${appId} (HTTP ${res.status}): the service account lacks the Firebase App Distribution Viewer role on project '${fb.project}', or firebase.app_id_${platform} is wrong`,
      );
    }
    const payload = (await res.json().catch(() => undefined)) as { releases?: ApiRelease[] } | undefined;
    if (!payload || typeof payload !== "object") {
      throw new ActionError("FIREBASE_LIST_FAILED", `the releases API answered something that is not JSON for the ${platform} app ${appId}`);
    }
    for (const r of payload.releases ?? []) {
      out.push({
        platform,
        app_id: appId,
        release: r.name ?? null,
        version: r.displayVersion ?? null,
        build: r.buildVersion ?? null,
        created_at: r.createTime ?? null,
        release_notes: r.releaseNotes?.text ?? null,
        console_url: r.firebaseConsoleUri ?? null,
        testing_url: r.testingUri ?? null,
      });
    }
  }
  return out;
}
