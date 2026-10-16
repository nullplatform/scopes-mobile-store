/**
 * Which asset of a release is the binary of each platform. The scope's
 * asset_name is the source of truth: the first platform of the scope deploys
 * exactly that asset; the other platform of a 'both' scope swaps the platform
 * prefix ('android-internal' → 'ios-internal', 'android' → 'ios'). A scope
 * without asset_name deploys its first platform's name — and create-scope
 * writes that name into the scope, because the platform rejects a deployment
 * of a scope without one.
 */

import { ActionError } from "@nullplatform/plugin/package";
import { deps } from "../deps";
import { ASSET_TYPE, type Context, type Platform, text } from "../scope/schema";

export const ASSET_NAME_PATTERN = /^[a-z0-9][a-z0-9._-]*$/;

const patchHint = (scopeId: string | undefined, name: string) =>
  `np scope patch --id ${scopeId ?? "<scope id>"} --body '{"asset_name":"${name}"}'`;

export function validateAssetName(name: string, suggestion: string, scopeId?: string): void {
  if (ASSET_NAME_PATTERN.test(name)) return;
  throw new ActionError(
    "INVALID_ASSET_NAME",
    `invalid asset name '${name}': it must be lowercase letters, digits, dots, underscores and dashes, starting with a letter or digit. Fix it with: ${patchHint(scopeId, suggestion)}`,
  );
}

/** The asset of `platform` for a scope whose first platform is `primary` and whose asset is `assetName`. */
export function platformAssetName(assetName: string, primary: Platform, platform: Platform, scopeId?: string): string {
  if (platform === primary) return assetName;
  if (assetName === primary) return platform;
  if (assetName.startsWith(`${primary}-`)) return `${platform}${assetName.slice(primary.length)}`;
  throw new ActionError(
    "ASSET_NAME_UNDERIVABLE",
    `cannot derive the ${platform} asset name from the scope's asset name '${assetName}': a scope with both platforms names its asset '${primary}' or '${primary}-<suffix>', so the ${platform} binary is '${platform}' or '${platform}-<suffix>'. Fix it with: ${patchHint(scopeId, primary)}`,
  );
}

export type AssetNameSource = "context" | "scope" | "default";

/** The scope's asset name: the notification's scope, else the scope as the platform holds it, else the first platform. */
export async function resolveAssetName(
  ctx: Pick<Context, "api" | "scope">,
  scopeId: string,
  primary: Platform,
): Promise<{ name: string; source: AssetNameSource }> {
  let name = text((ctx.scope as { asset_name?: unknown } | undefined)?.asset_name);
  let source: AssetNameSource = "context";
  if (!name) {
    const scope = await readScope(ctx, scopeId);
    name = scope.asset_name;
    source = "scope";
  }
  if (!name) {
    name = primary;
    source = "default";
  }
  validateAssetName(name, primary, scopeId);
  return { name, source };
}

async function readScope(ctx: Pick<Context, "api">, scopeId: string) {
  try {
    return await deps.platform.scope(ctx, scopeId);
  } catch (err) {
    throw new ActionError(
      "SCOPE_UNREADABLE",
      `could not read scope ${scopeId} to resolve its asset name (${err instanceof Error ? err.message : String(err)}): guessing the name could deploy the wrong binary. Check that the agent API key can read it and retry`,
    );
  }
}

/** Every platform's asset name, derived up front so a 'both' scope with an underivable name fails before anything else. */
export function assetNames(assetName: string, platforms: Platform[], scopeId?: string): Record<Platform, string> {
  const primary = platforms[0];
  const out = {} as Record<Platform, string>;
  for (const platform of platforms) out[platform] = platformAssetName(assetName, primary, platform, scopeId);
  return out;
}

/**
 * create-scope / update-scope: the scope keeps the asset name it has (validated,
 * and derivable for every platform), or gets its first platform's name.
 */
export async function ensureAssetName(
  ctx: Pick<Context, "api" | "scope">,
  scopeId: string,
  platforms: Platform[],
): Promise<{ name: string; set: boolean }> {
  const primary = platforms[0];
  let current = text((ctx.scope as { asset_name?: unknown } | undefined)?.asset_name);
  if (!current) current = (await readScope(ctx, scopeId)).asset_name;
  if (current) {
    validateAssetName(current, primary, scopeId);
    assetNames(current, platforms, scopeId);
    return { name: current, set: false };
  }
  try {
    await deps.platform.patchScope(ctx, scopeId, { asset_name: primary });
  } catch (err) {
    throw new ActionError(
      "ASSET_NAME_NOT_SET",
      `could not set the asset name of scope ${scopeId} to '${primary}' (${err instanceof Error ? err.message : String(err)}); without an asset name the platform rejects every deployment of the scope. Set it with: ${patchHint(scopeId, primary)}`,
    );
  }
  return { name: primary, set: true };
}

export interface ReleaseAsset {
  platform: Platform;
  name: string;
  url: string;
  assetId?: string;
  buildId?: string;
}

/** The binary of every platform in build `buildId`: the asset named for it, of the scope's asset type. */
export async function buildAssets(
  ctx: Pick<Context, "api">,
  buildId: string,
  names: Record<Platform, string>,
  release: string,
  type = ASSET_TYPE,
): Promise<ReleaseAsset[]> {
  let listed;
  try {
    listed = await deps.platform.assets(ctx, buildId);
  } catch (err) {
    throw new ActionError(
      "ASSETS_UNLISTABLE",
      `could not list the assets of build ${buildId}: ${err instanceof Error ? err.message : String(err)}`,
    );
  }
  const out: ReleaseAsset[] = [];
  for (const [platform, name] of Object.entries(names) as Array<[Platform, string]>) {
    const asset = listed.find((a) => a.name === name && a.type === type);
    if (!asset?.url) {
      throw new ActionError(
        "NO_ASSET",
        `no asset named '${name}' of type '${type}' in release ${release} (build ${buildId}): register an asset named '${name}' (type ${type}) in the CI, or change the scope's asset name`,
      );
    }
    out.push({ platform, name, url: asset.url, assetId: asset.id, buildId: asset.build_id ?? buildId });
  }
  return out;
}

/** The binaries of the release with `semver` of the application: what a rollback distributes again. */
export async function releaseAssets(
  ctx: Pick<Context, "api">,
  applicationId: string,
  semver: string,
  names: Record<Platform, string>,
  type = ASSET_TYPE,
): Promise<ReleaseAsset[]> {
  let releases;
  try {
    releases = await deps.platform.releases(ctx, applicationId);
  } catch (err) {
    throw new ActionError(
      "RELEASES_UNLISTABLE",
      `could not list the releases of application ${applicationId}: ${err instanceof Error ? err.message : String(err)}`,
    );
  }
  const release = releases.find((r) => r.semver === semver);
  if (!release?.build_id) {
    throw new ActionError(
      "NO_RELEASE",
      `no release ${semver} in application ${applicationId}: it was deleted, belongs to another application or has no build`,
    );
  }
  return buildAssets(ctx, release.build_id, names, semver, type);
}
