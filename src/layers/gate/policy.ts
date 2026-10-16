/**
 * The approval gate's policy, fail closed: production on a public store
 * (app-store, google-play) needs the store-review gate; on a private
 * distribution (firebase, foundry-eas, intune) gate none is allowed with a
 * warning. Unknown channels, gates and distributions are refused.
 */

import { ActionError } from "@nullplatform/plugin/package";
import type { Channel } from "../../scope/schema";

export const PUBLIC_STORES = ["app-store", "google-play"] as const;
export const PRIVATE_DISTRIBUTIONS = ["firebase", "foundry-eas", "intune"] as const;

export interface GateVerdict {
  /** A production publish without an external approval, when the policy allows it. */
  warning?: string;
}

/** Whether `channel` may be published on `distribution` with `gate`; throws when it may not. */
export function gatePolicy(channel: Channel, distribution: string, gate: string): GateVerdict {
  if (channel === "internal" || channel === "testers") return {};
  if (!distribution) {
    throw new ActionError("CONFIGURATION_INCOMPLETE", "cannot apply the production gate policy: the distribution layer is not set");
  }
  if ((PUBLIC_STORES as readonly string[]).includes(distribution)) {
    if (gate === "store-review") return {};
    throw new ActionError(
      "GATE_REQUIRED",
      `publishing to production on ${distribution} requires gate_layer=store-review (channel ${channel}, gate '${gate || "(not set)"}'): set gate_layer to store-review in the scope configuration of this namespace or dimension, or use the internal or testers channel, which do not reach the public store`,
    );
  }
  if ((PRIVATE_DISTRIBUTIONS as readonly string[]).includes(distribution)) {
    if (gate === "store-review") return {};
    if (gate === "none") {
      return {
        warning: `Publishing to production on ${distribution} without an external approval gate: testers get the build as soon as it is uploaded.`,
      };
    }
    throw new ActionError(
      "UNKNOWN_GATE",
      `unknown gate layer '${gate || "(not set)"}' for channel ${channel}: set gate_layer in the 'Mobile store' scope configuration to none or store-review`,
    );
  }
  throw new ActionError(
    "UNKNOWN_DISTRIBUTION",
    `unknown distribution layer '${distribution}': cannot decide whether production needs an approval gate (classify it as a public store or a private distribution in layers/gate/policy.ts)`,
  );
}
