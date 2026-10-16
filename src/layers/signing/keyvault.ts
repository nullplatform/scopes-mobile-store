/**
 * Signing layer `keyvault`: the Android binary is signed with the release
 * keystore stored in Secrets Manager under android.keystore_secret, a JSON
 * object {keystore_base64, keystore_password, key_alias, key_password}, with
 * apksigner, which the worker image must carry (the Android build-tools; see
 * the Dockerfile). The keystore lives next to the binary, mode 600, for the
 * length of the step; passwords travel to apksigner through environment
 * variables only and never reach the log. iOS signing is not implemented yet.
 */

import { chmod, mkdir, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { ActionError, type Narrative } from "@nullplatform/plugin/package";
import { deps } from "../../deps";
import type { ScopeConfiguration } from "../../platform/configuration";
import type { Context } from "../../scope/schema";
import { validateScopeSecretName } from "../../support/aws";
import { lastWords } from "../../support/cli";
import type { Binary } from "../binaries/fetch";
import type { Signed, SigningOptions } from "./index";

export interface KeystoreSecret {
  keystore_base64: string;
  keystore_password: string;
  key_alias: string;
  key_password: string;
}

/** The keystore secret, as the layer wants it; INVALID_KEYSTORE_SECRET otherwise. */
export function parseKeystoreSecret(name: string, raw: string): KeystoreSecret {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    parsed = undefined;
  }
  const s = parsed as Partial<KeystoreSecret> | undefined;
  if (
    !s ||
    typeof s !== "object" ||
    typeof s.keystore_base64 !== "string" ||
    !s.keystore_base64 ||
    typeof s.keystore_password !== "string" ||
    typeof s.key_alias !== "string" ||
    !s.key_alias ||
    typeof s.key_password !== "string"
  ) {
    throw new ActionError(
      "INVALID_KEYSTORE_SECRET",
      `secret '${name}' is not a keystore secret: store it as {"keystore_base64": "<base64 of the .jks>", "keystore_password": "...", "key_alias": "...", "key_password": "..."}`,
    );
  }
  return s as KeystoreSecret;
}

export async function signWithKeystore(
  ctx: Pick<Context, "log">,
  step: Narrative,
  binaries: Binary[],
  cfg: ScopeConfiguration,
  opts: SigningOptions,
): Promise<Signed[]> {
  if (binaries.some((b) => b.platform === "ios")) {
    throw new ActionError(
      "IOS_SIGNING_NOT_IMPLEMENTED",
      "iOS signing with the keyvault layer is not implemented yet: use the prebuilt signing layer (sign in the CI) for scopes that publish ios until keyvault supports it",
    );
  }
  const android = binaries.find((b) => b.platform === "android");
  if (!android) throw new ActionError("NO_BINARY", "the keyvault signing layer found no Android binary to sign");
  const secretName = cfg.android?.keystore_secret?.trim();
  if (!secretName) {
    throw new ActionError(
      "CONFIGURATION_INCOMPLETE",
      "android.keystore_secret is not set in the 'Mobile store' scope configuration: the signing layer is keyvault, so set it to the name of the secret that holds the release keystore",
    );
  }
  validateScopeSecretName(secretName, "android.keystore_secret", "mobile/android-keystore");
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
  const secret = parseKeystoreSecret(secretName, raw);
  const dir = dirname(android.path);
  const keystore = join(dir, "keystore.jks");
  const signed = join(dir, "app-signed.apk");
  await mkdir(dir, { recursive: true, mode: 0o700 });
  try {
    const b64 = secret.keystore_base64.replace(/\s+/g, "");
    if (!/^[A-Za-z0-9+/]+={0,2}$/.test(b64) || b64.length % 4 !== 0) throw new Error("not base64");
    const bytes = Buffer.from(b64, "base64");
    if (!bytes.length) throw new Error("empty");
    await Bun.write(keystore, bytes);
    await chmod(keystore, 0o600);
  } catch {
    await rm(keystore, { force: true });
    throw new ActionError(
      "INVALID_KEYSTORE_SECRET",
      `secret '${secretName}' is not a keystore secret: keystore_base64 is not valid base64 (store the keystore as base64 -w0 of the .jks file)`,
    );
  }
  try {
    ctx.log.detail(`signing ${android.path} with alias '${secret.key_alias}'`);
    const env = { MOBILE_STORE_KEYSTORE_PASSWORD: secret.keystore_password, MOBILE_STORE_KEY_PASSWORD: secret.key_password };
    const onLine = (line: string) => ctx.log.detail(line);
    const result = await deps.run(
      "apksigner",
      [
        "sign",
        "--ks",
        keystore,
        "--ks-pass",
        "env:MOBILE_STORE_KEYSTORE_PASSWORD",
        "--ks-key-alias",
        secret.key_alias,
        "--key-pass",
        "env:MOBILE_STORE_KEY_PASSWORD",
        "--out",
        signed,
        android.path,
      ],
      { env, signal: opts.signal, onLine },
    );
    if (result.exitCode !== 0) {
      throw new ActionError(
        "SIGNING_FAILED",
        `apksigner could not sign ${android.path}: ${lastWords(result)}. The keystore password, key alias or key password in secret '${secretName}' may be wrong, or keystore_base64 is not a JKS/PKCS12 keystore`,
      );
    }
    const verify = await deps.run("apksigner", ["verify", signed], { signal: opts.signal, onLine });
    if (verify.exitCode !== 0) {
      throw new ActionError(
        "SIGNATURE_INVALID",
        `the signature of ${signed} does not verify: ${lastWords(verify)}. Make the CI upload an unsigned (or debug-signed) APK when the signing layer is keyvault`,
      );
    }
  } finally {
    await rm(keystore, { force: true });
  }
  ctx.log.detail(`android: signed ${android.path} -> ${signed} (alias '${secret.key_alias}')`);
  step.explain({
    what: `The Android binary was signed with the release keystore from secret '${secretName}' (alias '${secret.key_alias}') and the signature verifies.`,
    why: "The scope configuration's signing layer is 'keyvault': the CI ships an unsigned binary and the platform holds the release key.",
  });
  step.output("signed-binary", { platform: "android", path: signed, alias: secret.key_alias, keystore_secret: secretName });
  return binaries.map((b) => ({ ...b, signedPath: b.platform === "android" ? signed : b.path }));
}
