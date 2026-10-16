/**
 * The scope's attributes: the three choices a developer makes — which
 * platforms, which channel, how much of the audience first — typed and
 * validated. Everything else (signing, distribution, approval gate, bucket,
 * credentials) is the platform team's: the "Mobile store" scope configuration
 * resolved for the scope's dimensions (config.ts). Handlers import from here;
 * the scope itself lives in resources.ts so resources → handlers → schema
 * never forms a cycle.
 */

import { ActionError, type ContextFor } from "@nullplatform/plugin/package";
import type { NpJSONSchema } from "@nullplatform/plugin/schema";

/** Mobile binaries are registered as bundle assets: the asset API only accepts the platform's built-in types. */
export const ASSET_TYPE = "bundle";

export const PLATFORM_CHOICES = ["android", "ios", "both"] as const;
export type PlatformChoice = (typeof PLATFORM_CHOICES)[number];
export const PLATFORMS = ["android", "ios"] as const;
export type Platform = (typeof PLATFORMS)[number];
export const CHANNELS = ["internal", "testers", "production"] as const;
export type Channel = (typeof CHANNELS)[number];
export const DEFAULT_ROLLOUT = 5;

export const schema = {
  type: "object",
  // The console's scope form shows exactly the properties listed here: the
  // core API builds the scope type's form schema with
  // `_.pick(schema.properties, schema.required)`. Every input has a default.
  required: ["platform", "channel", "rollout_percentage"],
  properties: {
    platform: {
      type: "string",
      title: "Platform",
      description:
        "Which mobile binaries this scope publishes. The build must produce the matching artifacts (APK/AAB for Android, IPA for iOS).",
      default: "android",
      oneOf: [
        { const: "android", title: "Android" },
        { const: "ios", title: "iOS" },
        { const: "both", title: "Android and iOS" },
      ],
      editableOn: ["create"],
      order: 1,
    },
    channel: {
      type: "string",
      title: "Distribution channel",
      description: "Who receives each deployment: your own team, a wider group of beta testers, or every end user.",
      default: "internal",
      oneOf: [
        { const: "internal", title: "Internal testers" },
        { const: "testers", title: "External testers / beta" },
        { const: "production", title: "Production" },
      ],
      editableOn: ["create", "update"],
      order: 2,
    },
    rollout_percentage: {
      type: "integer",
      title: "Initial rollout percentage",
      description:
        "Share of users that gets a new version first, on channels that support gradual rollout. Channels without gradual rollout ignore this value and deliver to everyone at once.",
      default: DEFAULT_ROLLOUT,
      minimum: 1,
      maximum: 100,
      editableOn: ["create", "update"],
      order: 3,
    },
  },
} as const satisfies NpJSONSchema;

/** The console's form for the three inputs; the platform stores it inside attributes.schema.uiSchema. */
export const uiSchema = {
  type: "VerticalLayout",
  elements: [
    { type: "Control", label: "Platform", scope: "#/properties/platform" },
    { type: "Control", label: "Distribution channel", scope: "#/properties/channel" },
    { type: "Control", label: "Initial rollout percentage", scope: "#/properties/rollout_percentage" },
  ],
} as const;

/** ctx.params, as the schema describes it: every input has a default, so nothing is required of the caller. */
export interface Attributes {
  platform?: string;
  channel?: string;
  rollout_percentage?: number | string;
}

/** The attributes with the schema's defaults applied and validated: what the handlers work with. */
export interface ResolvedAttributes {
  platform: PlatformChoice;
  /** The platforms the scope publishes, first one first: it names the scope's asset. */
  platforms: Platform[];
  channel: Channel;
  rolloutPercentage: number;
}

/** `android` → [android]; `both` → [android, ios]: the first platform is the scope's primary one. */
export const platformsOf = (choice: PlatformChoice): Platform[] =>
  choice === "both" ? ["android", "ios"] : [choice];

export const text = (v: unknown): string | undefined => (v === undefined || v === null || v === "" ? undefined : String(v));

/** What every handler receives: ctx.params typed from the schema exactly as the SDK types it for this resource. */
export type Context = ContextFor<typeof schema>;

export function attributes(ctx: Pick<Context, "params">): ResolvedAttributes {
  const p = ctx.params as Partial<Attributes>;
  const platform = text(p.platform) ?? "android";
  if (!(PLATFORM_CHOICES as readonly string[]).includes(platform)) {
    throw new ActionError(
      "UNSUPPORTED_PLATFORM",
      `unsupported platform '${platform}': the scope's platform must be android, ios or both (recreate the scope choosing one; the platform is only editable on create)`,
    );
  }
  const channel = text(p.channel) ?? "internal";
  if (!(CHANNELS as readonly string[]).includes(channel)) {
    throw new ActionError(
      "UNSUPPORTED_CHANNEL",
      `unsupported channel '${channel}': update the scope and choose internal, testers or production`,
    );
  }
  const raw = p.rollout_percentage;
  const rollout = raw === undefined || raw === null || raw === "" ? DEFAULT_ROLLOUT : Number(raw);
  if (!Number.isInteger(rollout) || rollout < 1 || rollout > 100) {
    throw new ActionError(
      "INVALID_ROLLOUT",
      `rollout_percentage must be an integer between 1 and 100, got '${String(raw)}': update the scope`,
    );
  }
  const choice = platform as PlatformChoice;
  return { platform: choice, platforms: platformsOf(choice), channel: channel as Channel, rolloutPercentage: rollout };
}
