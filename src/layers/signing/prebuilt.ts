/**
 * Signing layer `prebuilt`: the CI signs the binaries before registering them
 * as assets, so the layer only promotes each binary to its signed self.
 */

import type { Narrative } from "@nullplatform/plugin/package";
import type { Binary } from "../binaries/fetch";
import type { Context } from "../../scope/schema";
import type { Signed } from "./index";

export function passThrough(ctx: Pick<Context, "log">, step: Narrative, binaries: Binary[]): Signed[] {
  for (const b of binaries) ctx.log.detail(`${b.platform}: using the CI-signed binary ${b.path}`);
  const names = binaries.map((b) => b.platform).join(" and ");
  step.explain({
    what: `The ${names} binar${binaries.length === 1 ? "y is" : "ies are"} used as the CI signed ${binaries.length === 1 ? "it" : "them"}.`,
    why: "The scope configuration's signing layer is 'prebuilt': the CI signs the binaries before it registers them as assets.",
  });
  return binaries.map((b) => ({ ...b, signedPath: b.path }));
}
