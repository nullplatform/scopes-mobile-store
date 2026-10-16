/**
 * The binaries layer (the old platform/android and platform/ios): the binary of each platform, downloaded from the
 * assets bucket into the deployment's scratch directory and checked to be
 * what it claims — a zip carrying AndroidManifest.xml (an APK) or
 * Payload/<name>.app/Info.plist (an IPA). Only urls inside the configured
 * bucket are accepted: the agent role is broader than any single scope.
 */

import { chmod, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { ActionError, type Narrative } from "@nullplatform/plugin/package";
import type { ReleaseAsset } from "../../platform/assets";
import type { AwsCredentials } from "../../support/aws";
import { deps } from "../../deps";
import type { Context, Platform } from "../../scope/schema";
import { zipEntries } from "./zip";

export interface Binary {
  platform: Platform;
  path: string;
  asset: ReleaseAsset;
}

const SHAPE: Record<Platform, { ext: string; entry: RegExp; what: string; ci: string }> = {
  android: {
    ext: "apk",
    entry: /(^|\/)AndroidManifest\.xml$/,
    what: "an Android package (no AndroidManifest.xml inside)",
    ci: "the Android build",
  },
  ios: {
    ext: "ipa",
    entry: /^Payload\/[^/]+\.app\/Info\.plist$/,
    what: "an iOS package (no Payload/*.app/Info.plist inside)",
    ci: "the Xcode archive",
  },
};

export type AssetLocation = { kind: "s3"; bucket: string; key: string } | { kind: "https"; url: string };

/** Where the asset is, if it is inside `bucket`: s3://bucket/key, or the bucket's virtual-hosted https url. */
export function locateAsset(url: string, bucket: string): AssetLocation {
  const outside = () =>
    new ActionError(
      "ASSET_OUTSIDE_BUCKET",
      `asset url is outside the configured assets bucket '${bucket}': ${url}. Make the CI upload the binaries to s3://${bucket} and register that url, or set assets.bucket to the bucket the CI uses`,
    );
  if (url.startsWith("s3://")) {
    const rest = url.slice("s3://".length);
    const slash = rest.indexOf("/");
    const b = slash === -1 ? rest : rest.slice(0, slash);
    const key = slash === -1 ? "" : rest.slice(slash + 1);
    if (b !== bucket || !key) throw outside();
    return { kind: "s3", bucket, key };
  }
  if (url.startsWith("https://")) {
    let parsed: URL;
    try {
      parsed = new URL(url);
    } catch {
      throw outside();
    }
    const host = parsed.host;
    const regional = host.match(/^(.+)\.s3\.([a-z0-9-]+)\.amazonaws\.com$/);
    const plain = host === `${bucket}.s3.amazonaws.com`;
    if ((plain || (regional && regional[1] === bucket)) && parsed.pathname.length > 1) return { kind: "https", url };
    throw outside();
  }
  throw new ActionError(
    "UNSUPPORTED_ASSET_URL",
    `unsupported asset url '${url}': only s3:// and https:// are supported; make the CI upload the binary to the assets bucket and register its s3:// url`,
  );
}

export interface FetchOptions {
  bucket: string;
  region: string;
  credentials?: AwsCredentials;
  signal?: AbortSignal;
}

/** Downloads the asset to `destination`: S3 with the scope's credentials, or https (https only, also on redirects). */
export async function downloadAsset(url: string, destination: string, opts: FetchOptions): Promise<void> {
  const where = locateAsset(url, opts.bucket);
  await mkdir(dirname(destination), { recursive: true, mode: 0o700 });
  if (where.kind === "s3") {
    const bytes = await deps.aws.getObject(where.bucket, where.key, opts.region, opts.credentials);
    await Bun.write(destination, bytes);
    return;
  }
  const res = await deps.fetch(where.url, { redirect: "follow", signal: opts.signal });
  if (!res.ok) throw new Error(`HTTP ${res.status} fetching ${where.url}`);
  if (res.url && !res.url.startsWith("https://")) throw new Error(`${where.url} redirected to a non-https url`);
  await Bun.write(destination, new Uint8Array(await res.arrayBuffer()));
}

/** The binary of one platform, downloaded and checked; told on the step. */
export async function fetchBinary(
  ctx: Pick<Context, "log">,
  step: Narrative,
  asset: ReleaseAsset,
  workdir: string,
  opts: FetchOptions,
): Promise<Binary> {
  const shape = SHAPE[asset.platform];
  const destination = join(workdir, asset.platform, `app.${shape.ext}`);
  ctx.log.detail(`${asset.platform}: downloading ${asset.url} to ${destination}`);
  try {
    await downloadAsset(asset.url, destination, opts);
  } catch (err) {
    if (err instanceof ActionError) throw err;
    throw new ActionError(
      "ASSET_DOWNLOAD_FAILED",
      `could not download the ${asset.platform} binary from ${asset.url}: ${err instanceof Error ? err.message : String(err)}. Grant the scope's role read access to the assets bucket, or rebuild the release so the CI uploads the asset again`,
    );
  }
  await chmod(destination, 0o600).catch(() => {});
  const entries = await zipEntries(destination).catch((err) => {
    throw new ActionError(
      "NOT_A_MOBILE_BINARY",
      `${destination} is not ${shape.what}: the file is not a zip archive (${err instanceof Error ? err.message : String(err)}). Make the CI upload the ${shape.ext.toUpperCase()} produced by ${shape.ci} as the '${asset.name}' asset`,
    );
  });
  if (!entries.some((e) => shape.entry.test(e))) {
    throw new ActionError(
      "NOT_A_MOBILE_BINARY",
      `${destination} is not ${shape.what}. Make the CI upload the ${shape.ext.toUpperCase()} produced by ${shape.ci} as the '${asset.name}' asset, or check the download was not truncated`,
    );
  }
  const size = Bun.file(destination).size;
  step.output(`${asset.platform}-binary`, { asset: asset.name, url: asset.url, path: destination, bytes: size, entries: entries.length });
  ctx.log.detail(`${asset.platform}: ${destination} is ${shape.ext.toUpperCase()} (${entries.length} entries, ${size} bytes)`);
  return { platform: asset.platform, path: destination, asset };
}
