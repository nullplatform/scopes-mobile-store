/**
 * The story's static half: what each action is for and the steps it runs,
 * named exactly as the handlers' `ctx.step` calls, in the stages the
 * console's deployment timeline shows. The handlers add the facts at run
 * time (which release, which group, which Firebase release).
 */

import { Actions } from "@nullplatform/plugin/package";

const STAGES = {
  prepare: { key: "prepare", title: "Prepare" },
  fetch: { key: "fetch", title: "Fetch" },
  sign: { key: "sign", title: "Sign" },
  distribute: { key: "distribute", title: "Distribute" },
  record: { key: "record", title: "Record" },
  verify: { key: "verify", title: "Verify" },
  clean: { key: "clean", title: "Clean up" },
};

export const STEP = {
  checkActiveRollout: {
    key: "check active rollout",
    title: "Check no other rollout is in progress",
    description: "Two overlapping rollouts would distribute two releases to the same group and leave no clear deployment to finalize or roll back.",
    group: STAGES.prepare.key,
  },
  resolveContext: {
    key: "resolve context",
    title: "Resolve the deployment",
    description: "Which release, which scope and dimensions, which platforms and channel, and the 'Mobile store' scope configuration that applies: the signing, distribution and gate layers and the assets bucket.",
    group: STAGES.prepare.key,
  },
  assumeRole: {
    key: "assume role",
    title: "Assume the scope's role",
    description: "The IAM role the platform's identity provider names for this scope, so the agent's own role stays narrow: it reads the assets bucket and the distribution secrets.",
    group: STAGES.prepare.key,
  },
  resolveAssets: {
    key: "resolve assets",
    title: "Resolve the release's binaries",
    description: "The asset of each platform in the release's build, named after the scope's asset name ('android', 'ios', or 'android-<suffix>' / 'ios-<suffix>').",
    group: STAGES.prepare.key,
  },
  resolvePreviousAssets: {
    key: "resolve previous assets",
    title: "Resolve the previous release's binaries",
    description: "The binaries of the release the platform held as the scope's active deployment: Firebase cannot unpublish, so a rollback distributes them again.",
    group: STAGES.prepare.key,
  },
  downloadBinaries: {
    key: "download binaries",
    title: "Download the binaries",
    description: "Each platform's binary from the assets bucket into the deployment's scratch directory, checked to be an APK or an IPA.",
    group: STAGES.fetch.key,
  },
  sign: {
    key: "sign",
    title: "Sign the binaries",
    description: "The signing layer: the CI-signed binaries as they are (prebuilt), or the Android binary signed with the keystore in the secrets manager (keyvault).",
    group: STAGES.sign.key,
  },
  setupDistribution: {
    key: "setup distribution",
    title: "Set up the distribution",
    description: "The Firebase project and apps from the scope configuration, and the service account that uploads to them, read from the secrets manager.",
    group: STAGES.distribute.key,
  },
  gate: {
    key: "gate",
    title: "Apply the approval gate",
    description: "Production on a public store needs a store review; on a private distribution it may go without, with a warning.",
    group: STAGES.distribute.key,
  },
  publish: {
    key: "publish",
    title: "Publish to the channel",
    description: "Each binary uploaded to its Firebase app and distributed to the tester group named by the channel; the result recorded on the deployment.",
    group: STAGES.distribute.key,
  },
  recordRolloutState: {
    key: "record rollout state",
    title: "Record the rollout state",
    description: "Firebase App Distribution has no staged rollout: the release already reached the whole group, so the state is recorded on the deployment and nothing moves.",
    group: STAGES.record.key,
  },
  removeScratch: {
    key: "remove scratch directory",
    title: "Remove the scratch directory",
    description: "The binaries and signing leftovers of this deployment; its releases stay in the Firebase console, which cannot unpublish.",
    group: STAGES.clean.key,
  },
  resolveConfiguration: {
    key: "resolve configuration",
    title: "Resolve the scope configuration",
    description: "The 'Mobile store' scope configuration for the scope's dimensions must exist and name layers this worker implements, before any deployment needs them.",
    group: STAGES.verify.key,
  },
  ensureAssetName: {
    key: "ensure asset name",
    title: "Ensure the scope's asset name",
    description: "The platform picks a release's asset by the scope's asset name and rejects a deployment without one: a scope created through the API gets its first platform's name.",
    group: STAGES.verify.key,
  },
};

const deploy = (title: string, description: string, first: Array<(typeof STEP)[keyof typeof STEP]> = []) => ({
  title,
  description,
  groups: [STAGES.prepare, STAGES.fetch, STAGES.sign, STAGES.distribute],
  steps: [...first, STEP.resolveContext, STEP.assumeRole, STEP.resolveAssets, STEP.downloadBinaries, STEP.sign, STEP.setupDistribution, STEP.gate, STEP.publish],
});

const rollout = (title: string, description: string) => ({
  title,
  description,
  groups: [STAGES.prepare, STAGES.record],
  steps: [STEP.resolveContext, STEP.recordRolloutState],
});

const verify = (title: string, description: string) => ({
  title,
  description,
  groups: [STAGES.verify],
  steps: [STEP.resolveConfiguration, STEP.ensureAssetName],
});

/** Each action's name, intent and expected steps, in stages: the run's plan on the trace. */
export const plans = {
  [Actions.CREATE_SCOPE]: verify(
    "Create the scope",
    "Checks that the 'Mobile store' scope configuration resolves for the scope's dimensions and names implemented layers, and that the scope has the asset name the platform needs to deploy it.",
  ),
  [Actions.UPDATE_SCOPE]: verify("Update the scope", "Re-checks the scope configuration and the asset name for the changed inputs."),
  [Actions.START_INITIAL]: deploy(
    "Publish the release",
    "Downloads the release's binaries, signs them if asked, applies the approval gate and publishes them to the channel's tester group on Firebase App Distribution.",
  ),
  [Actions.START_BLUE_GREEN]: deploy(
    "Publish the release",
    "The same as a first publish, refused while another deployment of the scope is still rolling out: Firebase has no traffic split, so the release reaches the whole group.",
    [STEP.checkActiveRollout],
  ),
  [Actions.ROLLBACK_DEPLOYMENT]: {
    title: "Roll back to the previous release",
    description: "Firebase App Distribution cannot unpublish: the previous release's binaries are downloaded, signed and distributed again so they become the group's latest build.",
    groups: [STAGES.prepare, STAGES.fetch, STAGES.sign, STAGES.distribute],
    steps: [STEP.resolveContext, STEP.assumeRole, STEP.resolvePreviousAssets, STEP.downloadBinaries, STEP.sign, STEP.setupDistribution, STEP.publish],
  },
  [Actions.SWITCH_TRAFFIC]: rollout(
    "Switch traffic",
    "Firebase App Distribution has no staged rollout, so nothing moves; the requested weight is acknowledged and recorded on the deployment.",
  ),
  [Actions.FINALIZE_BLUE_GREEN]: rollout(
    "Finalize the deployment",
    "Records the final state on the deployment; Firebase is not touched.",
  ),
  [Actions.DELETE_DEPLOYMENT]: {
    title: "Retire the deployment",
    description: "Removes the deployment's scratch directory. Firebase App Distribution cannot unpublish a release, so its releases stay in the console until deleted by hand.",
    groups: [STAGES.clean],
    steps: [STEP.removeScratch],
  },
};
