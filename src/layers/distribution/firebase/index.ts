/**
 * Distribution layer: Firebase App Distribution, through its REST API — the
 * same calls the firebase CLI makes, without the CLI. The setup validates the
 * firebase section of the "Mobile store" scope configuration (project,
 * credentials secret, the app id of every platform the scope publishes) and
 * reads the service account from Secrets Manager; the key stays in memory for
 * the length of the action and is never written to disk nor logged. The
 * service account needs the Firebase App Distribution Admin role on the
 * project, and the developer's channel must exist as a tester group alias.
 *
 *   index.ts       the setup and the layer's contract
 *   distribute.ts  publish and rollback: upload a release, distribute it to the group
 *   releases.ts    instance:data: the releases of each app
 *   token.ts       a Google access token from the service account (no gcloud)
 */

import { ActionError, type Narrative } from "@nullplatform/plugin/package";
import { deps } from "../../../deps";
import type { ScopeConfiguration } from "../../../platform/configuration";
import type { Context, Platform } from "../../../scope/schema";
import { validateScopeSecretName, type AwsCredentials } from "../../../support/aws";

export const LAYER = "firebase";

export interface ServiceAccount {
  client_email: string;
  private_key: string;
  token_uri?: string;
  project_id?: string;
}

export interface FirebaseSetup {
  project: string;
  appIds: Partial<Record<Platform, string>>;
  /** The service account, in memory only. */
  account: ServiceAccount;
  secretName: string;
}

/** The App Distribution API's origin (FIREBASE_APP_DISTRIBUTION_URL overrides it, as it does for the firebase CLI). */
export const apiOrigin = (): string =>
  (deps.env.FIREBASE_APP_DISTRIBUTION_URL || "https://firebaseappdistribution.googleapis.com").replace(/\/+$/, "");

/** `projects/<number>/apps/<app id>`: the app's resource name. */
export const appName = (appId: string): string => `projects/${projectNumberOf(appId)}/apps/${appId}`;

export interface SetupOptions {
  region: string;
  credentials?: AwsCredentials;
}

export function validateFirebaseProject(project: string): void {
  if (/^[a-z0-9-]+$/.test(project)) return;
  throw new ActionError(
    "INVALID_CONFIGURATION",
    `firebase.project '${project}' is not a Firebase project id: copy the project id from the Firebase console (Project settings > General), lowercase letters, digits and dashes only`,
  );
}

export function validateFirebaseAppId(platform: Platform, appId: string): void {
  if (/^1:[0-9]+:(android|ios):[a-f0-9]+$/.test(appId) && appId.split(":")[2] === platform) return;
  throw new ActionError(
    "INVALID_CONFIGURATION",
    `firebase.app_id_${platform} '${appId}' is not a Firebase ${platform} app id: copy it from the Firebase console (Project settings > Your apps), it looks like 1:1234567890:${platform}:abcdef0123456789`,
  );
}

/** The project number the REST API wants in its paths: the second segment of every app id. */
export const projectNumberOf = (appId: string): string => appId.split(":")[1] ?? "";

/** The service account JSON, or NOT_A_SERVICE_ACCOUNT. */
export function parseServiceAccount(secretName: string, raw: string): ServiceAccount {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    parsed = undefined;
  }
  const sa = parsed as Partial<ServiceAccount> | undefined;
  if (!sa || typeof sa !== "object" || typeof sa.client_email !== "string" || typeof sa.private_key !== "string") {
    throw new ActionError(
      "NOT_A_SERVICE_ACCOUNT",
      `secret '${secretName}' is not a Google service account JSON: store the full JSON key of a service account with the Firebase App Distribution Admin role`,
    );
  }
  return sa as ServiceAccount;
}

/** Validates the Firebase configuration for `platforms` and reads the service account; told on the step. */
export async function setupFirebase(
  ctx: Pick<Context, "log">,
  step: Narrative,
  cfg: ScopeConfiguration,
  platforms: Platform[],
  opts: SetupOptions,
): Promise<FirebaseSetup> {
  const fb = cfg.firebase ?? {};
  const missing: string[] = [];
  const project = fb.project?.trim() ?? "";
  const secretName = fb.credentials_secret?.trim() ?? "";
  if (!project) missing.push("firebase.project");
  else validateFirebaseProject(project);
  if (!secretName) missing.push("firebase.credentials_secret");
  const appIds: Partial<Record<Platform, string>> = {};
  for (const platform of platforms) {
    const id = (platform === "android" ? fb.app_id_android : fb.app_id_ios)?.trim() ?? "";
    if (!id) missing.push(`firebase.app_id_${platform}`);
    else {
      validateFirebaseAppId(platform, id);
      appIds[platform] = id;
    }
  }
  if (missing.length) {
    throw new ActionError(
      "CONFIGURATION_INCOMPLETE",
      `the 'Mobile store' scope configuration is incomplete for Firebase App Distribution: missing ${missing.join(", ")}. Register the app${platforms.length > 1 ? "s" : ""} in the Firebase project '${project || "<project>"}' and set the missing field${missing.length > 1 ? "s" : ""} (firebase.project is the project id, firebase.credentials_secret the name of the secret with the service account JSON, firebase.app_id_<platform> like 1:1234567890:<platform>:abcdef)`,
    );
  }
  validateScopeSecretName(secretName, "firebase.credentials_secret", "mobile/firebase-sa");
  ctx.log.detail(`firebase project ${project}: ${platforms.map((p) => `${p} ${appIds[p]}`).join(", ")}`);
  ctx.log.detail(`reading secret '${secretName}'`);
  let raw: string;
  try {
    raw = await deps.aws.getSecret(secretName, opts.region, opts.credentials);
  } catch (err) {
    throw new ActionError(
      "SECRET_UNREADABLE",
      `could not read secret '${secretName}' from the secrets manager in ${opts.region}: ${err instanceof Error ? err.message : String(err)}. Create the secret or grant the scope's role secretsmanager:GetSecretValue on it`,
    );
  }
  const account = parseServiceAccount(secretName, raw);
  ctx.log.detail(`service account: ${account.client_email}`);
  step.explain({
    what: `Firebase project ${project} with ${platforms.map((p) => `the ${p} app ${appIds[p]}`).join(" and ")}, as ${account.client_email}.`,
    why: "The scope configuration's distribution layer is 'firebase': the developer's channel is a tester group of these apps, and the service account in the secret is who uploads to it.",
  });
  step.output("firebase", { project, apps: appIds, service_account: account.client_email, credentials_secret: secretName });
  return { project, appIds, account, secretName };
}

/** The App Distribution page of an app in the Firebase console. */
export const consoleUrl = (project: string, appId: string): string =>
  `https://console.firebase.google.com/project/${project}/appdistribution/app/${appId}/releases`;
