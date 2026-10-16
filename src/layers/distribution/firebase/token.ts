/**
 * A Google access token for the Firebase service account, without gcloud: a
 * JWT (RS256, signed with the account's private key) exchanged at Google's
 * token endpoint. The endpoint must be exactly
 * https://oauth2.googleapis.com/token (the key's token_uri, or the default
 * when it has none): the signed assertion is never sent anywhere else, and
 * nothing of the key is ever logged.
 */

import { createSign } from "node:crypto";
import { ActionError } from "@nullplatform/plugin/package";
import { deps } from "../../../deps";
import type { ServiceAccount } from "./index";

export const GOOGLE_TOKEN_URI = "https://oauth2.googleapis.com/token";
const SCOPE = "https://www.googleapis.com/auth/cloud-platform";
const LIFETIME_SECONDS = 3600;

const base64url = (input: string | Buffer): string =>
  Buffer.from(input).toString("base64").replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");

/** The signed assertion: header.claims.signature, as the token endpoint wants it. */
export function assertionFor(account: ServiceAccount, now = Math.floor(Date.now() / 1000)): string {
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(
    JSON.stringify({ iss: account.client_email, scope: SCOPE, aud: GOOGLE_TOKEN_URI, iat: now, exp: now + LIFETIME_SECONDS }),
  );
  const signature = createSign("RSA-SHA256").update(`${header}.${claims}`).sign(account.private_key);
  return `${header}.${claims}.${base64url(signature)}`;
}

export async function accessToken(account: ServiceAccount): Promise<string> {
  const tokenUri = account.token_uri ?? GOOGLE_TOKEN_URI;
  if (tokenUri !== GOOGLE_TOKEN_URI) {
    throw new ActionError(
      "NOT_A_SERVICE_ACCOUNT",
      `unexpected token_uri '${tokenUri}' in the service account: only ${GOOGLE_TOKEN_URI} is allowed; store the JSON key exactly as Google Cloud generated it`,
    );
  }
  let assertion: string;
  try {
    assertion = assertionFor(account);
  } catch (err) {
    throw new ActionError(
      "NOT_A_SERVICE_ACCOUNT",
      `the service account's private key cannot sign: ${err instanceof Error ? err.message : String(err)}; store the JSON key exactly as Google Cloud generated it`,
    );
  }
  const body = new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion });
  let res: Response;
  try {
    res = await deps.fetch(tokenUri, { method: "POST", body, signal: AbortSignal.timeout(60_000) });
  } catch (err) {
    throw ActionError.retry("GOOGLE_TOKEN_FAILED", `could not reach ${tokenUri}: ${err instanceof Error ? err.message : String(err)}`);
  }
  if (!res.ok) {
    const said = (await res.text().catch(() => "")).slice(0, 300);
    throw new ActionError(
      "GOOGLE_TOKEN_FAILED",
      `could not obtain a Google access token for ${account.client_email} (HTTP ${res.status}${said ? `: ${said}` : ""}): the key was deleted or the service account disabled, or the worker clock is off; create a new key and update the credentials secret`,
    );
  }
  const token = ((await res.json().catch(() => ({}))) as { access_token?: unknown }).access_token;
  if (typeof token !== "string" || !token) {
    throw new ActionError("GOOGLE_TOKEN_FAILED", `the token endpoint ${tokenUri} answered without an access_token`);
  }
  return token;
}
