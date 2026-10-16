/**
 * The gate layer: whether a deployment waits for an external approval before
 * it counts as finished. Picked by the scope configuration's `gate_layer`:
 *
 *   none          no external approval; the policy may still refuse it
 *   store-review  wait for the store review asynchronously — declared, not implemented yet
 */

import { ActionError, type Narrative } from "@nullplatform/plugin/package";
import type { Channel, Context } from "../../scope/schema";
import { gatePolicy } from "./policy";

/** Runs the gate layer: approved, or an error that says why the deployment may not continue. */
export async function runGate(
  ctx: Pick<Context, "log">,
  step: Narrative,
  gate: string,
  channel: Channel,
  distribution: string,
): Promise<"approved"> {
  if (gate === "none") {
    const verdict = gatePolicy(channel, distribution, "none");
    if (verdict.warning) {
      ctx.log.detail(verdict.warning);
      step.explain({
        severity: "warn",
        what: verdict.warning,
        why: "The scope configuration's gate layer is 'none' and the channel is production: the policy allows it on a private distribution, not on a public store.",
      });
    } else {
      step.explain({
        what: `No external approval is required for the ${channel} channel.`,
        why: "The scope configuration's gate layer is 'none'; only production on a public store would need a store review.",
      });
    }
    return "approved";
  }
  if (gate === "store-review") {
    throw new ActionError(
      "LAYER_NOT_IMPLEMENTED",
      "the gate layer 'store-review' (wait for the store review asynchronously) is not implemented yet; use gate_layer none until it is",
    );
  }
  throw new ActionError(
    "UNKNOWN_LAYER",
    `unknown gate layer '${gate}': set the gate layer in the 'Mobile store' scope configuration to none or store-review`,
  );
}
