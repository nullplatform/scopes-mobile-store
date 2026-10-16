/**
 * The seams the tests replace, in one place: the command-line tools, AWS,
 * the network, the platform and the worker's environment. Production uses
 * the real ones; a test swaps what it needs, and no test spawns a tool or
 * reaches AWS, Firebase or the platform.
 */

import { platform, type Platform } from "./platform/api";
import { aws, type AwsApi } from "./support/aws";
import { run, type Runner } from "./support/cli";

export const deps: {
  run: Runner;
  aws: AwsApi;
  fetch: (input: string | URL | Request, init?: RequestInit) => Promise<Response>;
  platform: Platform;
  env: Record<string, string | undefined>;
} = {
  run,
  aws,
  fetch: (input, init) => fetch(input, init),
  platform,
  env: process.env,
};
