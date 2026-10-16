/**
 * The scope actions. Creating or updating a scope deploys nothing: it checks
 * that the "Mobile store" scope configuration resolves for the scope's
 * dimensions and names layers this worker implements, before any deployment
 * needs them, and that the scope has the asset name the platform needs to
 * deploy it. Deleting a scope has nothing to undo: the scope owns no cloud
 * resource, and the releases it distributed stay in the distribution console.
 */

import { deps } from "../../deps";
import { ensureAssetName } from "../../platform/assets";
import { checkLayer, formatDimensions, resolveConfiguration } from "../../platform/configuration";
import { attributes, type Context } from "../schema";

const idOf = (v: unknown): string | undefined => (v === undefined || v === null || v === "" ? undefined : String(v));

export async function createScope(ctx: Context): Promise<void> {
  const attrs = attributes(ctx);
  const cfg = await ctx.step("resolve configuration", async (step) => {
    const resolved = await resolveConfiguration(ctx, "all", deps.env);
    const c = resolved.configuration;
    for (const type of ["signing", "distribution", "gate"] as const) {
      const name = checkLayer(type, c[`${type}_layer`]);
      ctx.log.detail(`${type} layer '${name}' is available`);
    }
    ctx.log.detail(`assets s3://${c.assets.bucket} (${c.assets.region}) | configuration from ${resolved.source}`);
    step.explain({
      what: `For dimensions ${formatDimensions(resolved.dimensions)}: signing ${c.signing_layer}, distribution ${c.distribution_layer}, gate ${c.gate_layer}, assets in s3://${c.assets.bucket}; all three layers are implemented by this worker.`,
      why: `The 'Mobile store' scope configuration (from ${resolved.source}) is what every deployment of this scope will run with; a missing or unsupported layer fails here instead of at the first deployment.`,
    });
    step.output("configuration", {
      signing_layer: c.signing_layer,
      distribution_layer: c.distribution_layer,
      gate_layer: c.gate_layer,
      assets: c.assets,
      ...(c.firebase?.project ? { firebase_project: c.firebase.project } : {}),
      source: resolved.source,
    });
    return resolved;
  });
  const scopeId = idOf(ctx.scopeId) ?? (await deps.platform.context(ctx)).scope.id;
  const asset = await ctx.step("ensure asset name", async (step) => {
    const result = await ensureAssetName(ctx, scopeId, attrs.platforms);
    ctx.log.detail(result.set ? `asset name ${result.name} (the scope had none; set to its first platform)` : `asset name ${result.name} (set in the scope)`);
    step.explain({
      what: result.set
        ? `The scope had no asset name; it now deploys the asset named '${result.name}', its first platform.`
        : `The scope deploys the asset named '${result.name}'${attrs.platforms.length > 1 ? `, and '${result.name.replace(/^android/, "ios")}' for iOS` : ""}.`,
      why: "The platform picks a release's asset by the scope's asset name and rejects a deployment of a scope without one; the CI registers one asset per binary under that name.",
    });
    step.output("asset_name", { name: result.name, set_by_this_action: result.set });
    return result;
  });
  ctx.trace.explain({
    title: "Scope ready to publish",
    what: `${attrs.platforms.join(" and ")} to the ${attrs.channel} channel through ${cfg.configuration.distribution_layer}${cfg.configuration.firebase?.project ? ` (project ${cfg.configuration.firebase.project})` : ""}, signed by ${cfg.configuration.signing_layer}, gate ${cfg.configuration.gate_layer}; asset name '${asset.name}'.`,
    why: "Creating the scope deploys nothing; this proves the configuration and the asset name a first deployment will need.",
    next: "Register a release whose build carries the binaries as assets, then deploy it to this scope.",
  });
  ctx.trace.output("scope", { platforms: attrs.platforms, channel: attrs.channel, rollout_percentage: attrs.rolloutPercentage, asset_name: asset.name });
}

/** update-scope: the inputs changed; the configuration and the asset name are checked again. */
export const updateScope = createScope;

export async function deleteScope(ctx: Context): Promise<void> {
  ctx.log.ok("nothing to do: the scope owns no cloud resources (distributed releases stay in the distribution console)");
  ctx.trace.explain({
    title: "Nothing to remove",
    what: "The scope owns no cloud resource; the releases it distributed stay in the Firebase console, which cannot unpublish.",
    why: "Each deployment was retired before the scope; a Firebase release is removed by hand, in the console, when it must not be installed any more.",
  });
}
