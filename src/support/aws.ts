/**
 * AWS, as the scope needs it: the role the platform's IAM provider names for
 * this scope (assumed with STS, so the agent's own role stays narrow), the
 * binary the CI uploaded to the assets bucket (S3), and the distribution and
 * signing secrets (Secrets Manager). The SDK clients are behind one small
 * interface so the tests never reach AWS.
 */

import { GetObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { GetSecretValueCommand, SecretsManagerClient } from "@aws-sdk/client-secrets-manager";
import { AssumeRoleCommand, STSClient } from "@aws-sdk/client-sts";
import { ActionError } from "@nullplatform/plugin/package";
import type { IamProvider } from "../platform/configuration";

export interface AwsCredentials {
  accessKeyId: string;
  secretAccessKey: string;
  sessionToken?: string;
}

export interface AwsApi {
  assumeRole(roleArn: string, sessionName: string, region: string): Promise<AwsCredentials>;
  getObject(bucket: string, key: string, region: string, credentials?: AwsCredentials): Promise<Uint8Array>;
  getSecret(name: string, region: string, credentials?: AwsCredentials): Promise<string>;
}

export const aws: AwsApi = {
  async assumeRole(roleArn, sessionName, region) {
    const sts = new STSClient({ region });
    const res = await sts.send(new AssumeRoleCommand({ RoleArn: roleArn, RoleSessionName: sessionName }));
    const c = res.Credentials;
    if (!c?.AccessKeyId || !c.SecretAccessKey || !c.SessionToken) {
      throw new ActionError("ASSUME_ROLE_FAILED", `sts:AssumeRole returned incomplete credentials for ${roleArn}`);
    }
    return { accessKeyId: c.AccessKeyId, secretAccessKey: c.SecretAccessKey, sessionToken: c.SessionToken };
  },
  async getObject(bucket, key, region, credentials) {
    const s3 = new S3Client({ region, ...(credentials ? { credentials } : {}) });
    const res = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
    if (!res.Body) throw new Error(`s3://${bucket}/${key} has no body`);
    return res.Body.transformToByteArray();
  },
  async getSecret(name, region, credentials) {
    const sm = new SecretsManagerClient({ region, ...(credentials ? { credentials } : {}) });
    const res = await sm.send(new GetSecretValueCommand({ SecretId: name }));
    if (typeof res.SecretString !== "string") throw new Error(`secret ${name} has no SecretString`);
    return res.SecretString;
  },
};

// ─── The role ─────────────────────────────────────────────────────────

/** The selector the IAM provider names this scope's role by (MOBILE_STORE_ASSUME_ROLE_SELECTOR overrides it). */
export const DEFAULT_ROLE_SELECTOR = "mobile-store";

/**
 * The role to assume, or undefined for the agent's own credentials:
 *   1. MOBILE_STORE_ASSUME_ROLE_ARN (an explicit override; `none` says: use
 *      the credentials already in the environment, as a developer running the
 *      worker locally wants);
 *   2. the IAM provider's `iam_role_arns.arns[]` entry for the selector, as
 *      the platform resolved it for the scope's dimensions;
 *   3. MOBILE_STORE_ASSUME_ROLE_ARN_DEFAULT (a per-account default).
 */
export function resolveRoleArn(
  iam: IamProvider | undefined,
  env: Record<string, string | undefined>,
  selector = env.MOBILE_STORE_ASSUME_ROLE_SELECTOR || DEFAULT_ROLE_SELECTOR,
): string | undefined {
  const override = env.MOBILE_STORE_ASSUME_ROLE_ARN;
  if (override === "none") return undefined;
  if (override) return override;
  const named = (iam?.iam_role_arns?.arns ?? []).find((e) => e?.selector === selector)?.arn;
  if (named) return named;
  return env.MOBILE_STORE_ASSUME_ROLE_ARN_DEFAULT || undefined;
}

/** Secrets must live under the mobile/ prefix, what the scope's IAM policy allows; paths and ARNs are refused. */
export function validateScopeSecretName(name: string, field: string, example: string): void {
  if (/^mobile\/[a-zA-Z0-9/_-]+$/.test(name) && !name.includes("/../") && !name.includes("/./")) return;
  throw new ActionError(
    "SECRET_OUTSIDE_NAMESPACE",
    `secret name '${name}' is outside the mobile/ namespace (${field}): store the secret under the mobile/ prefix (e.g. ${example}) and set ${field} to that name`,
  );
}
