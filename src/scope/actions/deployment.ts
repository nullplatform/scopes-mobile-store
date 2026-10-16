/**
 * The deployment actions: publish a release (initial and blue-green), switch
 * traffic and finalize (acknowledged: Firebase has no staged rollout), roll
 * back (distribute the previous release again) and retire a deployment
 * (remove its scratch directory). Each is one function on the shared
 * `prepare`, which resolves the release, the scope configuration and the
 * asset names, then the layers run in order: binaries → signing →
 * distribution setup → gate → publish.
 */

import { join } from "node:path";
import { ActionError, type Narrative } from "@nullplatform/plugin/package";
import { deps } from "../../deps";
import { fetchBinary, type Binary } from "../../layers/binaries/fetch";
import { distributeAll, newSummary, type DistributionSummary } from "../../layers/distribution/firebase/distribute";
import { LAYER as FIREBASE, setupFirebase, type FirebaseSetup } from "../../layers/distribution/firebase/index";
import { runGate } from "../../layers/gate/index";
import { sign, type Signed } from "../../layers/signing/index";
import { activeRollout, previousDeployment, type ActionContext as Entities } from "../../platform/api";
import { assetNames, buildAssets, releaseAssets, resolveAssetName, type AssetNameSource, type ReleaseAsset } from "../../platform/assets";
import { checkLayer, environmentOf, formatDimensions, resolveConfiguration, type ResolvedConfiguration } from "../../platform/configuration";
import { deploymentWorkdir, removeWorkdir, workdirBase } from "../../platform/workdir";
import { resolveRoleArn, type AwsCredentials } from "../../support/aws";
import { attributes, type Context, type Platform, type ResolvedAttributes } from "../schema";

/** Everything a deployment action needs before any layer runs. */
export interface Prepared {
  attrs: ResolvedAttributes;
  cfg: ResolvedConfiguration;
  entities: Entities;
  scopeId: string;
  deploymentId: string;
  /** The environment dimension, what the release notes name. */
  environment: string;
  /** The asset name of each platform; absent in scope mode (switch traffic, finalize). */
  names?: Record<Platform, string>;
  assetName?: { name: string; source: AssetNameSource };
  /** The deployment a rollback returns to; resolved in rollback mode only. */
  previous?: { id: string; semver?: string };
  workdir: string;
}

type Mode = "deployment" | "rollback" | "scope";

const MESSAGES = {
  distribution: "MOBILE_STORE_DISTRIBUTION",
  partial: "MOBILE_STORE_DISTRIBUTION_PARTIAL",
  rollback: "MOBILE_STORE_ROLLBACK",
  rollout: "MOBILE_STORE_ROLLOUT",
} as const;

const idOf = (v: unknown): string | undefined => (v === undefined || v === null || v === "" ? undefined : String(v));

/**
 * The deployment as the platform holds it, the scope's attributes and its
 * configuration, the layers checked to be implemented, the asset names and
 * the scratch directory; told on the step.
 */
export async function prepare(ctx: Context, step: Narrative, mode: Mode): Promise<Prepared> {
  const attrs = attributes(ctx);
  const cfg = await resolveConfiguration(ctx, "all", deps.env);
  const entities = await deps.platform.context(ctx);
  const scopeId = idOf(ctx.scopeId) ?? entities.scope.id;
  const deploymentId = idOf(ctx.deploymentId) ?? entities.deployment?.id ?? "";
  if (!/^[0-9]+$/.test(scopeId)) throw new ActionError("NO_SCOPE", `the action names no scope (got '${scopeId}')`);
  if (!/^[0-9]+$/.test(deploymentId)) throw new ActionError("NO_DEPLOYMENT", `the action names no deployment (got '${deploymentId}')`);
  const { configuration: c } = cfg;
  checkLayer("signing", c.signing_layer);
  checkLayer("distribution", c.distribution_layer);
  checkLayer("gate", c.gate_layer);
  const environment = environmentOf(cfg.dimensions);
  const release = entities.release;
  const semver = release?.semver ?? release?.id ?? "?";
  const base = workdirBase(deps.env);
  const workdir = await deploymentWorkdir(deploymentId, base);
  const prepared: Prepared = { attrs, cfg, entities, scopeId, deploymentId, environment, workdir };

  ctx.log.detail(
    `scope ${entities.namespace.slug}/${entities.application.slug}/${entities.scope.slug ?? scopeId} (id ${scopeId}), dimensions ${formatDimensions(cfg.dimensions)}, deployment ${deploymentId}, release ${semver}`,
  );
  ctx.log.detail(`platforms ${attrs.platforms.join(" ")} | channel ${attrs.channel} | rollout ${attrs.rolloutPercentage}%`);
  ctx.log.detail(`layers: signing ${c.signing_layer}, distribution ${c.distribution_layer}, gate ${c.gate_layer} | assets s3://${c.assets.bucket} (${c.assets.region}) | configuration from ${cfg.source}`);

  if (mode !== "scope") {
    const assetName = await resolveAssetName(ctx, scopeId, attrs.platforms[0]);
    prepared.assetName = assetName;
    prepared.names = assetNames(assetName.name, attrs.platforms, scopeId);
    ctx.log.detail(`asset name ${assetName.name} (${assetName.source === "default" ? "default: the scope has no asset name" : `from the ${assetName.source}`})`);
  }
  if (mode === "rollback") {
    const deployments = await deps.platform.deployments(ctx, scopeId).catch((err) => {
      throw new ActionError("DEPLOYMENTS_UNLISTABLE", `could not list the deployments of scope ${scopeId}: ${err instanceof Error ? err.message : String(err)}`);
    });
    const previous = previousDeployment(deployments, deploymentId);
    if (previous) {
      let previousSemver: string | undefined;
      if (previous.release_id) {
        previousSemver = await deps.platform
          .release(ctx, previous.release_id)
          .then((r) => r.semver)
          .catch(() => undefined);
      }
      prepared.previous = { id: previous.id, semver: previousSemver };
      ctx.log.detail(`previous deployment ${previous.id} (release ${previousSemver ?? "unknown"})`);
    } else {
      ctx.log.detail("previous deployment: none");
    }
  }

  step.explain({
    what: `Release ${semver} of ${entities.application.slug} for scope ${entities.scope.slug ?? scopeId} (${formatDimensions(cfg.dimensions)}): ${attrs.platforms.join(" and ")} to the ${attrs.channel} channel, signing ${c.signing_layer}, distribution ${c.distribution_layer}, gate ${c.gate_layer}.`,
    why: `The developer chose the platforms and the channel on the scope; the layers and the assets bucket come from the 'Mobile store' scope configuration ${cfg.source === "the platform" ? "the platform resolved for these dimensions" : "set through environment variables"}.`,
  });
  step.output("deployment", {
    scope_id: scopeId,
    deployment_id: deploymentId,
    release: semver,
    platforms: attrs.platforms,
    channel: attrs.channel,
    rollout_percentage: attrs.rolloutPercentage,
    layers: { signing: c.signing_layer, distribution: c.distribution_layer, gate: c.gate_layer },
    assets_bucket: c.assets.bucket,
    ...(prepared.names ? { asset_names: prepared.names } : {}),
    ...(prepared.previous ? { previous_deployment: prepared.previous } : {}),
  });
  return prepared;
}

/** The scope's role assumed, or the agent's own credentials; told on the step. */
export async function assumeRole(ctx: Context, step: Narrative, p: Prepared): Promise<AwsCredentials | undefined> {
  const arn = resolveRoleArn(p.cfg.iam, deps.env);
  if (!arn) {
    ctx.log.detail("assume role skipped: using the agent's credentials");
    step.explain({
      what: "The agent's own credentials are used: no role is named for this scope.",
      why: "The identity provider names no role for selector 'mobile-store' and no override is set; a developer running the worker locally sets MOBILE_STORE_ASSUME_ROLE_ARN=none on purpose.",
    });
    return undefined;
  }
  ctx.log.detail(`assuming role ${arn}`);
  try {
    const credentials = await deps.aws.assumeRole(arn, `np-mobile-store-${p.scopeId}`, p.cfg.configuration.assets.region);
    step.explain({
      what: `Assumed ${arn} for this action.`,
      why: "The identity provider names this role for selector 'mobile-store': it reads the assets bucket and the distribution secrets, so the agent's own role stays narrow.",
    });
    step.output("role", { arn, selector: deps.env.MOBILE_STORE_ASSUME_ROLE_SELECTOR || "mobile-store" });
    return credentials;
  } catch (err) {
    if (err instanceof ActionError) throw err;
    throw new ActionError(
      "ASSUME_ROLE_FAILED",
      `could not assume ${arn}: ${err instanceof Error ? err.message : String(err)}. The agent's role must be allowed to sts:AssumeRole it and the role must trust the agent's role`,
    );
  }
}

async function downloadAll(ctx: Context, step: Narrative, assets: ReleaseAsset[], p: Prepared, credentials: AwsCredentials | undefined, into: string): Promise<Binary[]> {
  const binaries: Binary[] = [];
  for (const asset of assets) {
    binaries.push(await fetchBinary(ctx, step, asset, into, { bucket: p.cfg.configuration.assets.bucket, region: p.cfg.configuration.assets.region, credentials, signal: ctx.signal }));
  }
  step.explain({
    what: `Downloaded ${binaries.map((b) => `the ${b.platform} binary (${b.asset.name})`).join(" and ")} from s3://${p.cfg.configuration.assets.bucket}.`,
    why: "The binaries are what the CI registered as the release's assets; each is checked to be an APK or an IPA before anything is signed or published.",
  });
  return binaries;
}

async function recordMessage(ctx: Context, deploymentId: string, level: "INFO" | "ERROR", code: string, text: string): Promise<boolean> {
  const ok = await deps.platform.message(ctx, deploymentId, level, code, text);
  ctx.log.detail(ok ? `recorded ${code} on deployment ${deploymentId}` : `could not record ${code} on deployment ${deploymentId}; the summary stays in the trace`);
  return ok;
}

interface PublishStory {
  code: typeof MESSAGES.distribution | typeof MESSAGES.rollback;
  title: string;
  why: string;
  releaseNotes: string;
}

/** Publishes the signed binaries through Firebase and records the summary on the deployment. */
async function publish(ctx: Context, step: Narrative, p: Prepared, fb: FirebaseSetup, signed: Signed[], summary: DistributionSummary, story: PublishStory): Promise<DistributionSummary> {
  try {
    await distributeAll(ctx, step, fb, signed, p.attrs.channel, summary, { releaseNotes: story.releaseNotes, signal: ctx.signal });
  } catch (err) {
    if (summary.partial) {
      await recordMessage(ctx, p.deploymentId, "ERROR", MESSAGES.partial, `mobile-store partial distribution (the releases below stay distributed): ${JSON.stringify(summary)}`);
    }
    throw err;
  }
  const recorded = await recordMessage(ctx, p.deploymentId, "INFO", story.code, `mobile-store ${story.code === MESSAGES.rollback ? "rollback" : "distribution"}: ${JSON.stringify(summary)}`);
  const releases = Object.entries(summary.releases) as Array<[Platform, NonNullable<DistributionSummary["releases"][Platform]>]>;
  step.explain({
    what: `${releases.map(([platform, r]) => `${platform} release ${r.name ?? "(unnamed)"}${r.version ? ` (version ${r.version}${r.build ? ` build ${r.build}` : ""})` : ""}`).join(" and ")} distributed to Firebase group '${summary.group}' of project ${summary.project}.`,
    why: "The developer's channel names a tester group of the Firebase apps; Firebase has no staged rollout, so the whole group gets the build at once.",
    ...(recorded ? {} : { impact: "The platform refused the deployment message that records this summary; the trace keeps it." }),
  });
  ctx.trace.explain({
    title: story.title,
    what: `${releases.map(([platform]) => platform).join(" and ")} of ${p.entities.application.slug} ${summary.rollback_to ?? p.entities.release?.semver ?? ""} ${summary.rollback_to ? "distributed again" : "distributed"} to Firebase group '${summary.group}' (${p.environment}); rollout 100%, as Firebase has no staged rollout.`,
    why: story.why,
    next: "Testers in the group get the build from the Firebase App Tester app or the testing link; the console link opens the release.",
  });
  for (const [platform, r] of releases) {
    if (r.console_url) ctx.trace.link({ rel: "firebase-console", uri: r.console_url, label: `${platform} release in Firebase` });
    if (r.testing_url) ctx.trace.link({ rel: "firebase-testing", uri: r.testing_url, label: `${platform} testing page` });
  }
  ctx.trace.output("distribution", summary);
  return summary;
}

// ─── Actions ──────────────────────────────────────────────────────────

/** start-initial: download, sign, gate and publish the binaries of the release. */
export async function startInitial(ctx: Context): Promise<void> {
  const p = await ctx.step("resolve context", (step) => prepare(ctx, step, "deployment"));
  const credentials = await ctx.step("assume role", (step) => assumeRole(ctx, step, p));
  const release = p.entities.release;
  if (!release?.build_id) {
    throw new ActionError("NO_BUILD", `release ${release?.semver ?? release?.id ?? "?"} has no build: create the release from a build whose CI registered the mobile binaries as assets`);
  }
  const semver = release.semver ?? release.id;
  const assets = await ctx.step("resolve assets", async (step) => {
    const found = await buildAssets(ctx, release.build_id!, p.names!, semver);
    for (const a of found) ctx.log.detail(`${a.platform}: ${a.name} -> ${a.url}`);
    step.explain({
      what: `${found.map((a) => `${a.platform} is asset '${a.name}'`).join(", ")} of release ${semver} (build ${release.build_id}).`,
      why: `The scope's asset name is '${p.assetName!.name}' (${p.assetName!.source === "default" ? "its first platform, as the scope has none" : `from the ${p.assetName!.source}`}); the other platform of a scope with both swaps the platform prefix.`,
    });
    step.output("assets", found);
    return found;
  });
  const binaries = await ctx.step("download binaries", (step) => downloadAll(ctx, step, assets, p, credentials, p.workdir));
  const c = p.cfg.configuration;
  const signed = await ctx.step("sign", (step) => sign(ctx, step, c.signing_layer, binaries, c, { region: c.assets.region, credentials, signal: ctx.signal }));
  const fb = await ctx.step("setup distribution", (step) => setupFirebase(ctx, step, c, p.attrs.platforms, { region: c.assets.region, credentials }));
  await ctx.step("gate", (step) => runGate(ctx, step, c.gate_layer, p.attrs.channel, c.distribution_layer));
  await ctx.step("publish", (step) =>
    publish(ctx, step, p, fb, signed, newSummary(fb, p.attrs.channel), {
      code: MESSAGES.distribution,
      title: `Release ${semver} published to Firebase group '${p.attrs.channel}'`,
      why: "The scope publishes each release's binaries to the tester group its channel names; Firebase App Distribution is the distribution layer of this scope's configuration.",
      releaseNotes: `${p.entities.application.slug} ${semver} (${p.environment}) deployment ${p.deploymentId}`,
    }),
  );
}

/** start-blue-green: the initial publish, refused while another deployment of the scope is still rolling out. */
export async function startBlueGreen(ctx: Context): Promise<void> {
  await ctx.step("check active rollout", async (step) => {
    const scopeId = idOf(ctx.scopeId);
    const deploymentId = idOf(ctx.deploymentId);
    if (!scopeId || !deploymentId) throw new ActionError("NO_DEPLOYMENT", "the action names no scope or deployment");
    let deployments;
    try {
      deployments = await deps.platform.deployments(ctx, scopeId);
    } catch (err) {
      throw ActionError.retry(
        "DEPLOYMENTS_UNLISTABLE",
        `could not list the deployments of scope ${scopeId} to check for a rollout in progress (${err instanceof Error ? err.message : String(err)}); the deployment is not started`,
      );
    }
    const other = activeRollout(deployments, deploymentId);
    if (other) {
      throw new ActionError(
        "ROLLOUT_IN_PROGRESS",
        `a rollout is already in progress in scope ${scopeId} (deployment ${other.id}, ${other.status}); finalize or roll it back first, then start this deployment again`,
      );
    }
    ctx.log.detail(`no other rollout in progress in scope ${scopeId}`);
    step.explain({
      what: `No other deployment of scope ${scopeId} is rolling out.`,
      why: "Two overlapping rollouts would distribute two releases to the same group and leave no clear deployment to finalize or roll back.",
    });
  });
  await startInitial(ctx);
}

/** switch-traffic: Firebase has no staged rollout; the weight is acknowledged and the state recorded. */
export async function switchTraffic(ctx: Context): Promise<void> {
  const raw = ctx.weight ?? (ctx.params as { desired_traffic?: unknown }).desired_traffic;
  const weight = raw === undefined || raw === null || raw === "" ? undefined : Number(raw);
  if (weight === undefined || Number.isNaN(weight)) {
    throw new ActionError("NO_WEIGHT", "switch-traffic carries no traffic weight (desired_traffic)");
  }
  const p = await ctx.step("resolve context", (step) => prepare(ctx, step, "scope"));
  await ctx.step("record rollout state", async (step) => {
    const semver = p.entities.release?.semver ?? "?";
    const state = requireFirebase(p, "switch-traffic", `Firebase App Distribution has no staged rollout: release ${semver} is already available to all of group '${p.attrs.channel}'`);
    ctx.log.detail(state);
    await recordMessage(ctx, p.deploymentId, "INFO", MESSAGES.rollout, `mobile-store switch_traffic: ${state}`);
    await ctx.deployment.reportTraffic(weight);
    step.explain({
      what: `${weight}% of traffic acknowledged: ${state}.`,
      why: "The platform's blue-green strategy moves traffic between the previous deployment and this one in steps; a Firebase group has nothing to move, so each step is acknowledged as done.",
    });
  });
  ctx.trace.explain({
    title: `${weight}% of traffic acknowledged`,
    what: `Release ${p.entities.release?.semver ?? "?"} already reaches all of Firebase group '${p.attrs.channel}'; ${weight}% to deployment ${p.deploymentId} is recorded as done.`,
    why: "Firebase App Distribution has no staged rollout: the public stores do, but their distribution layers are not implemented yet.",
  });
}

/** finalize-blue-green: records the final state on the deployment; Firebase is not touched. */
export async function finalizeBlueGreen(ctx: Context): Promise<void> {
  const p = await ctx.step("resolve context", (step) => prepare(ctx, step, "scope"));
  await ctx.step("record rollout state", async (step) => {
    const semver = p.entities.release?.semver ?? "?";
    const state = requireFirebase(p, "finalize-blue-green", `Release ${semver} stays the latest build of Firebase group '${p.attrs.channel}'; nothing to change on Firebase`);
    ctx.log.detail(state);
    await recordMessage(ctx, p.deploymentId, "INFO", MESSAGES.rollout, `mobile-store finalize: ${state}`);
    step.explain({ what: `${state}.`, why: "A Firebase group has one latest build; finalizing the deployment only records that this release is it." });
  });
  ctx.trace.explain({
    title: "Deployment finalized",
    what: `Release ${p.entities.release?.semver ?? "?"} stays the latest build of Firebase group '${p.attrs.channel}' for deployment ${p.deploymentId}.`,
    why: "Firebase App Distribution has no staged rollout, so there was nothing left to move.",
  });
}

function requireFirebase(p: Prepared, action: string, state: string): string {
  const layer = p.cfg.configuration.distribution_layer;
  if (layer !== FIREBASE) {
    throw new ActionError(
      "LAYER_NOT_IMPLEMENTED",
      `${action} is not supported for distribution '${layer}' yet: the ${layer} distribution layer (staged rollout on the store) is not implemented; use the firebase distribution layer until it is`,
    );
  }
  return state;
}

/** rollback-deployment: distribute the previous release again (Firebase cannot unpublish), signed by the signing layer. */
export async function rollbackDeployment(ctx: Context): Promise<void> {
  const p = await ctx.step("resolve context", (step) => prepare(ctx, step, "rollback"));
  if (!p.previous) {
    throw new ActionError(
      "NO_PREVIOUS_DEPLOYMENT",
      `no previous finalized deployment to roll back to in scope ${p.scopeId}: this is the first deployment, or every earlier one failed or was deleted. Firebase App Distribution cannot unpublish a release: remove the testers from group '${p.attrs.channel}' in the Firebase console if this build must not be installed, or deploy a known-good release again`,
    );
  }
  if (!p.previous.semver) {
    throw ActionError.retry(
      "PREVIOUS_RELEASE_UNKNOWN",
      `the release of the previous deployment ${p.previous.id} could not be read; retry the rollback, or deploy the previous release again by hand`,
    );
  }
  const previous = p.previous.semver;
  const credentials = await ctx.step("assume role", (step) => assumeRole(ctx, step, p));
  const assets = await ctx.step("resolve previous assets", async (step) => {
    const found = await releaseAssets(ctx, p.entities.application.id, previous, p.names!);
    for (const a of found) ctx.log.detail(`${a.platform}: ${a.name} of release ${previous} -> ${a.url}`);
    step.explain({
      what: `${found.map((a) => `${a.platform} is asset '${a.name}'`).join(", ")} of release ${previous}, the one deployment ${p.previous!.id} shipped.`,
      why: "A rollback distributes the previous release again; its binaries go through the same checks as a deployment.",
    });
    step.output("assets", found);
    return found;
  });
  const into = join(p.workdir, "rollback");
  const binaries = await ctx.step("download binaries", (step) => downloadAll(ctx, step, assets, p, credentials, into));
  const c = p.cfg.configuration;
  const signed = await ctx.step("sign", (step) => sign(ctx, step, c.signing_layer, binaries, c, { region: c.assets.region, credentials, signal: ctx.signal }));
  const fb = await ctx.step("setup distribution", (step) => setupFirebase(ctx, step, c, p.attrs.platforms, { region: c.assets.region, credentials }));
  ctx.log.detail(`Firebase cannot unpublish release ${p.entities.release?.semver ?? "?"}: the previous build is distributed again to group '${p.attrs.channel}'`);
  await ctx.step("publish", (step) =>
    publish(ctx, step, p, fb, signed, newSummary(fb, p.attrs.channel, { rollback_to: previous }), {
      code: MESSAGES.rollback,
      title: `Rolled back to release ${previous}`,
      why: `Firebase App Distribution cannot unpublish release ${p.entities.release?.semver ?? "?"}: distributing ${previous} again makes it the group's latest build. Testers who already installed the rolled-back build keep it.`,
      releaseNotes: `${p.entities.application.slug} rollback to ${previous} (${p.environment}) deployment ${p.deploymentId}`,
    }),
  );
}

/**
 * delete-deployment, for every status the platform deletes from, failed
 * included: Firebase cannot unpublish, so only the scratch directory goes.
 * Never fails on what it cannot clean, and depends on nothing being resolvable.
 */
export async function deleteDeployment(ctx: Context): Promise<void> {
  const deploymentId = idOf(ctx.deploymentId);
  await ctx.step("remove scratch directory", async (step) => {
    ctx.log.detail("Firebase App Distribution cannot unpublish a release: the releases of this deployment stay in the console");
    if (!deploymentId || !/^[0-9]+$/.test(deploymentId)) {
      ctx.log.detail(`deployment id '${deploymentId ?? ""}' is not an integer; nothing removed`);
      step.explain({ what: "The action names no deployment; nothing was removed." });
      return;
    }
    const base = workdirBase(deps.env);
    const dir = join(base, deploymentId);
    let removed = false;
    try {
      removed = await removeWorkdir(dir, base);
    } catch (err) {
      ctx.log.detail(`could not remove the scratch directory ${dir}: ${err instanceof Error ? err.message : String(err)}`);
    }
    ctx.log.detail(removed ? `removed the scratch directory ${dir}` : `no scratch directory to remove (${dir})`);
    step.explain({
      what: removed ? `Removed the scratch directory ${dir}.` : `There was no scratch directory to remove (${dir}).`,
      why: "The binaries and signing leftovers live there for the length of the deployment; its Firebase releases stay in the console until deleted by hand.",
    });
  });
  ctx.trace.explain({
    title: `Deployment ${deploymentId ?? ""} retired`,
    what: "The deployment's scratch directory is gone; its releases stay in Firebase App Distribution, which cannot unpublish.",
    why: "Retiring a deployment on this scope has nothing else to undo.",
  });
}
