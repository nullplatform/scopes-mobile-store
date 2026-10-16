/**
 * The platform team's half of the scope: the "Mobile store" scope
 * configuration (category scope-configurations, slug mobile-store) resolved
 * for the scope's dimensions — which layers run (signing, distribution,
 * gate), the Firebase project and apps, the Android and iOS identities, the
 * assets bucket — and the IAM provider that names the role the scope
 * assumes. Both come from ctx.settings.providers, the SDK's equivalent of
 * `np service workflow build-context`: the deepest NRN that matches the
 * scope's dimensions wins. Environment variables stand in for a missing
 * configuration (a developer's local run, or an account not configured yet).
 */

import { ActionError } from "@nullplatform/plugin/package";
import type { Context } from "../scope/schema";
import { text } from "../scope/schema";

export const CONFIGURATION_CATEGORY = "scope-configurations";
export const CONFIGURATION_SLUG = "mobile-store";
export const IAM_CATEGORY = "identity-access-control";
export const DEFAULT_REGION = "us-east-1";

/** What the provider specification declares, and what this worker implements of it. */
export const LAYERS = {
  signing: { declared: ["prebuilt", "keyvault", "match"], implemented: ["prebuilt", "keyvault"] },
  distribution: {
    declared: ["firebase", "app-store", "google-play", "foundry-eas", "intune"],
    implemented: ["firebase"],
  },
  gate: { declared: ["none", "store-review"], implemented: ["none"] },
} as const;
export type LayerType = keyof typeof LAYERS;

export interface FirebaseConfiguration {
  project?: string;
  app_id_android?: string;
  app_id_ios?: string;
  credentials_secret?: string;
}

export interface ScopeConfiguration {
  signing_layer: string;
  distribution_layer: string;
  gate_layer: string;
  firebase?: FirebaseConfiguration;
  android?: { package?: string; keystore_secret?: string };
  ios?: { bundle_id?: string; app_store_connect_key_secret?: string };
  assets: { bucket: string; region: string };
}

export interface IamProvider {
  iam_role_arns?: { arns?: Array<{ selector?: string; arn?: string }> };
}

export type Dimensions = Record<string, string>;
export type ProvidersMap = Record<string, Record<string, unknown>>;

export interface ResolvedConfiguration {
  configuration: ScopeConfiguration;
  iam: IamProvider | undefined;
  dimensions: Dimensions;
  /** Where it came from, for the log. */
  source: "the platform" | "environment variables";
}

/** What a configuration must name: everything for a deployment, only the distribution for an instance listing. */
export type Require = "all" | "distribution";

/** The attributes of the specification `slug` in `category`, direct or nested under its slug; undefined when absent. */
export function attributesOf<T extends object>(
  providers: ProvidersMap,
  category: string,
  slug: string,
  marker: keyof T & string,
): T | undefined {
  const entry = providers[category];
  if (!entry || typeof entry !== "object") return undefined;
  const nested = (entry as Record<string, unknown>)[slug];
  if (nested && typeof nested === "object") return nested as T;
  return marker in entry ? (entry as T) : undefined;
}

/** The IAM provider's attributes: the category's entry itself, or whichever nested specification carries the role list. */
export function iamProviderOf(providers: ProvidersMap): IamProvider | undefined {
  const entry = providers[IAM_CATEGORY];
  if (!entry || typeof entry !== "object") return undefined;
  if ("iam_role_arns" in entry) return entry as IamProvider;
  for (const value of Object.values(entry)) {
    if (value && typeof value === "object" && "iam_role_arns" in (value as object)) return value as IamProvider;
  }
  return undefined;
}

// ─── Dimensions ───────────────────────────────────────────────────────

type DimensionsContext = Pick<Context, "settings" | "scope" | "service" | "log">;
const resolvedDimensions = new WeakMap<object, Promise<Dimensions>>();

/** The scope's dimensions, resolved once per action: the scope as the platform holds it, else the notification's. */
export function dimensions(ctx: DimensionsContext): Promise<Dimensions> {
  let hit = resolvedDimensions.get(ctx);
  if (!hit) {
    hit = resolveDimensions(ctx);
    resolvedDimensions.set(ctx, hit);
  }
  return hit;
}

async function resolveDimensions(ctx: DimensionsContext): Promise<Dimensions> {
  try {
    const { scope } = await ctx.settings.buildContext({ resources: ["scope"] });
    const own = stringDimensions((scope as { dimensions?: unknown } | undefined)?.dimensions);
    if (own) return own;
  } catch (err) {
    ctx.log.detail(`the scope could not be read for its dimensions: ${err instanceof Error ? err.message : String(err)}`);
  }
  return stringDimensions(ctx.scope?.dimensions) ?? stringDimensions(ctx.service?.dimensions) ?? {};
}

function stringDimensions(raw: unknown): Dimensions | undefined {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return undefined;
  const out: Dimensions = {};
  for (const [key, value] of Object.entries(raw as Record<string, unknown>)) {
    if (value !== undefined && value !== null && value !== "") out[key] = String(value);
  }
  return Object.keys(out).length ? out : undefined;
}

/** `environment=prod, country=uy` for a log line or an error. */
export function formatDimensions(dims: Dimensions): string {
  const entries = Object.entries(dims);
  return entries.length ? entries.map(([k, v]) => `${k}=${v}`).join(", ") : "none";
}

/** The environment dimension, what the release notes and the log name; `default` without one. */
export const environmentOf = (dims: Dimensions): string => dims.environment ?? "default";

// ─── Resolution ───────────────────────────────────────────────────────

const NAME = /^[a-z0-9-]+$/;
const BUCKET = /^[a-z0-9.-]+$/;

/**
 * The configuration for this scope: the "Mobile store" provider the platform
 * resolved for the scope's dimensions, else the environment variables
 * (SIGNING_LAYER, DISTRIBUTION_LAYER, GATE_LAYER, ASSETS_BUCKET,
 * ASSETS_REGION). Incomplete or malformed values fail here, before any
 * binary is downloaded.
 */
export async function resolveConfiguration(
  ctx: Pick<Context, "settings" | "scope" | "service" | "log">,
  require: Require,
  env: Record<string, string | undefined> = process.env,
): Promise<ResolvedConfiguration> {
  const dims = await dimensions(ctx);
  const providers = await ctx.settings.providers([CONFIGURATION_CATEGORY, IAM_CATEGORY], { dimensions: dims });
  const found = attributesOf<Partial<ScopeConfiguration>>(providers, CONFIGURATION_CATEGORY, CONFIGURATION_SLUG, "distribution_layer");
  const source: ResolvedConfiguration["source"] = found ? "the platform" : "environment variables";
  const configuration: ScopeConfiguration = {
    signing_layer: text(found?.signing_layer) ?? text(env.SIGNING_LAYER) ?? "",
    distribution_layer: text(found?.distribution_layer) ?? text(env.DISTRIBUTION_LAYER) ?? "",
    gate_layer: text(found?.gate_layer) ?? text(env.GATE_LAYER) ?? "",
    ...(found?.firebase ? { firebase: found.firebase } : {}),
    ...(found?.android ? { android: found.android } : {}),
    ...(found?.ios ? { ios: found.ios } : {}),
    assets: {
      bucket: text(found?.assets?.bucket) ?? text(env.ASSETS_BUCKET) ?? "",
      region: text(found?.assets?.region) ?? text(env.ASSETS_REGION) ?? DEFAULT_REGION,
    },
  };
  const missing: string[] = [];
  if (require === "all" && !configuration.signing_layer) missing.push("signing_layer");
  if (!configuration.distribution_layer) missing.push("distribution_layer");
  if (require === "all" && !configuration.gate_layer) missing.push("gate_layer");
  if (!configuration.assets.bucket) missing.push("assets.bucket");
  if (missing.length) {
    throw new ActionError(
      "CONFIGURATION_INCOMPLETE",
      `the Mobile store scope configuration is incomplete for dimensions ${formatDimensions(dims)}: missing ${missing.join(", ")}. Create a 'Mobile store' scope configuration (category scope-configurations) for the account, namespace or dimension of this scope, or set the SIGNING_LAYER, DISTRIBUTION_LAYER, GATE_LAYER and ASSETS_BUCKET environment variables`,
    );
  }
  for (const [type, value] of [
    ["signing", configuration.signing_layer],
    ["distribution", configuration.distribution_layer],
    ["gate", configuration.gate_layer],
  ] as const) {
    if (value && !NAME.test(value)) {
      throw new ActionError(
        "INVALID_CONFIGURATION",
        `invalid ${type} layer '${value}': only lowercase letters, digits and dashes are allowed; set the ${type} layer in the 'Mobile store' scope configuration to one of ${LAYERS[type].declared.join(", ")}`,
      );
    }
  }
  if (!BUCKET.test(configuration.assets.bucket)) {
    throw new ActionError(
      "INVALID_CONFIGURATION",
      `invalid assets bucket '${configuration.assets.bucket}': set assets.bucket to the bucket name only (lowercase letters, digits, dots and dashes; no scheme, path or spaces)`,
    );
  }
  if (!NAME.test(configuration.assets.region)) {
    throw new ActionError(
      "INVALID_CONFIGURATION",
      `invalid assets region '${configuration.assets.region}': set assets.region to a region name such as us-east-1`,
    );
  }
  return { configuration, iam: iamProviderOf(providers), dimensions: dims, source };
}

/** The layer this worker runs for `type`, or why it cannot: a name nobody declared, or one declared but not implemented yet. */
export function checkLayer(type: LayerType, name: string): string {
  const { declared, implemented } = LAYERS[type];
  if (!(declared as readonly string[]).includes(name)) {
    throw new ActionError(
      "UNKNOWN_LAYER",
      `unknown ${type} layer '${name}': set the ${type} layer in the 'Mobile store' scope configuration to one of ${declared.join(", ")}`,
    );
  }
  if (!(implemented as readonly string[]).includes(name)) {
    throw new ActionError(
      "LAYER_NOT_IMPLEMENTED",
      `the ${type} layer '${name}' is not implemented yet; this worker implements ${implemented.join(", ")}. Use one of those until '${name}' is supported`,
    );
  }
  return name;
}
