/**
 * The signing layer: how a binary gets its release signature before it is
 * published. One implementation per directory entry, picked by the scope
 * configuration's `signing_layer`:
 *
 *   prebuilt  the CI signed the binaries before it registered them
 *   keyvault  apksigner with a keystore from the secrets manager (Android)
 *   match     declared in the provider specification, not implemented yet
 */

import { ActionError, type Narrative } from "@nullplatform/plugin/package";
import type { AwsCredentials } from "../../support/aws";
import type { Binary } from "../binaries/fetch";
import type { ScopeConfiguration } from "../../platform/configuration";
import type { Context } from "../../scope/schema";
import { signWithKeystore } from "./keyvault";
import { passThrough } from "./prebuilt";

export interface Signed extends Binary {
  /** The file to distribute: the input itself (prebuilt) or the signed copy (keyvault). */
  signedPath: string;
}

export interface SigningOptions {
  region: string;
  credentials?: AwsCredentials;
  signal?: AbortSignal;
}

/** Signs (or passes through) every binary with the configured layer; told on the step. */
export async function sign(
  ctx: Pick<Context, "log">,
  step: Narrative,
  layer: string,
  binaries: Binary[],
  cfg: ScopeConfiguration,
  opts: SigningOptions,
): Promise<Signed[]> {
  switch (layer) {
    case "prebuilt":
      return passThrough(ctx, step, binaries);
    case "keyvault":
      return signWithKeystore(ctx, step, binaries, cfg, opts);
    default:
      throw new ActionError(
        "LAYER_NOT_IMPLEMENTED",
        `the signing layer '${layer}' is not implemented yet; this worker implements prebuilt, keyvault`,
      );
  }
}
