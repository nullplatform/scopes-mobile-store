/**
 * instance:data: the releases of the distribution channel, as the console
 * lists a scope's instances. Only the distribution layer runs: the Firebase
 * apps of the scope's platforms are listed through the App Distribution API
 * with the service account from the secrets manager.
 */

import { ActionError } from "@nullplatform/plugin/package";
import { deps } from "../../deps";
import { listReleases, type ReleaseInstance } from "../../layers/distribution/firebase/releases";
import { LAYER as FIREBASE, setupFirebase } from "../../layers/distribution/firebase/index";
import { resolveConfiguration } from "../../platform/configuration";
import { resolveRoleArn } from "../../support/aws";
import { attributes, type Context } from "../schema";

const silent = { explain() {}, link() {}, output() {} };

export async function listInstances(ctx: Context): Promise<{ results: ReleaseInstance[] }> {
  const attrs = attributes(ctx);
  const cfg = await resolveConfiguration(ctx, "distribution", deps.env);
  const c = cfg.configuration;
  if (c.distribution_layer !== FIREBASE) {
    throw new ActionError(
      "LAYER_NOT_IMPLEMENTED",
      `the distribution layer '${c.distribution_layer}' cannot list releases yet; this worker lists Firebase App Distribution releases`,
    );
  }
  const arn = resolveRoleArn(cfg.iam, deps.env);
  const credentials = arn
    ? await deps.aws.assumeRole(arn, `np-mobile-store-${ctx.scopeId || "instances"}`, c.assets.region)
    : undefined;
  const fb = await setupFirebase(ctx, silent, c, attrs.platforms, { region: c.assets.region, credentials });
  const results = await listReleases(fb, fb.account, attrs.platforms);
  ctx.log.detail(`${results.length} release${results.length === 1 ? "" : "s"} across ${attrs.platforms.join(", ")}`);
  return { results };
}
