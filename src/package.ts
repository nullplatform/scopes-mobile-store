import { definePackage } from "@nullplatform/plugin/package";
import { Tracer } from "@nullplatform/tracing";
import manifest from "../package.json" with { type: "json" };
import { target } from "./scope/resources";

/**
 * The platform's trace, continued: one run per action, one step per ctx.step.
 * The SDK would load @nullplatform/tracing itself behind NP_TRACING_URL, but
 * it does so with a dynamic import that a bun-compiled worker cannot resolve
 * (no node_modules inside the binary), so the tracer is built here, where the
 * import is static and bundled. Off when the agent passes no NP_TRACING_URL.
 */
type Tracing = NonNullable<Parameters<typeof definePackage>[0]["tracing"]>;
const tracing = process.env.NP_TRACING_URL
  ? (new Tracer({
      baseURL: process.env.NP_TRACING_URL,
      apiKey: process.env.NP_API_KEY ?? "",
      producer: manifest.name,
    }) as unknown as Tracing)
  : undefined;

export default definePackage({
  name: manifest.name,
  version: manifest.version,
  description: manifest.description,
  components: [target],
  ...(tracing ? { tracing } : {}),
});
