/**
 * What the platform knows that the scope needs, behind one object the tests
 * replace: the scope (its asset name), the deployments of the scope (the one
 * still rolling out, the previous finalized one), releases and their build
 * assets, and the deployment messages where the scope records what it did on
 * the distribution channel (PATCH /deployment only takes status,
 * strategy_data and messages).
 */

import type { Context } from "../scope/schema";

/** A typed-client answer, read loosely: the specs name some fields in camelCase the API sends in snake_case. */
type Answer = { data?: any; error?: unknown };

export interface ScopeRecord {
  id: string;
  slug?: string;
  asset_name?: string;
  dimensions?: Record<string, unknown>;
  capabilities?: Record<string, unknown>;
}

export interface DeploymentRecord {
  id: string;
  status?: string;
  status_in_scope?: string;
  release_id?: string;
  created_at?: string;
}

export interface ReleaseRecord {
  id: string;
  semver?: string;
  build_id?: string;
  application_id?: string;
}

export interface AssetRecord {
  id?: string;
  name?: string;
  type?: string;
  url?: string;
  build_id?: string;
}

export interface ActionContext {
  application: { id: string; slug: string };
  namespace: { slug: string };
  scope: ScopeRecord;
  deployment?: DeploymentRecord;
  release?: ReleaseRecord;
}

export type Level = "INFO" | "WARNING" | "ERROR";

type Api = Pick<Context, "api">;

const str = (v: unknown): string | undefined => (v === undefined || v === null || v === "" ? undefined : String(v));

function results(payload: unknown): any[] {
  if (Array.isArray(payload)) return payload;
  const inner = (payload as { results?: unknown } | null)?.results;
  return Array.isArray(inner) ? inner : [];
}

/** Up to `pages` pages of `limit`, the way `np … list --all --max-pages 5` reads them. */
async function listAll(ctx: Api, path: string, query: Record<string, unknown>, limit = 200, pages = 5): Promise<any[]> {
  const out: any[] = [];
  for (let page = 0; page < pages; page++) {
    const res = (await (ctx.api.GET as any)(path, { params: { query: { ...query, limit, offset: page * limit } } })) as Answer;
    if (res.error) throw new Error(`GET ${path} failed: ${JSON.stringify(res.error).slice(0, 200)}`);
    const rows = results(res.data);
    out.push(...rows);
    if (rows.length < limit) break;
  }
  return out;
}

export const platform = {
  /** The entities the action is about, as `np service workflow build-context` resolves them. */
  async context(ctx: Pick<Context, "settings">): Promise<ActionContext> {
    const c = (await ctx.settings.buildContext({
      resources: ["application", "namespace", "scope", "deployment", "release"],
    })) as Record<string, any>;
    const scope = c.scope ?? {};
    return {
      application: { id: String(c.application?.id ?? ""), slug: String(c.application?.slug ?? "") },
      namespace: { slug: String(c.namespace?.slug ?? "") },
      scope: {
        id: String(scope.id ?? ""),
        slug: str(scope.slug),
        asset_name: str(scope.asset_name),
        dimensions: scope.dimensions,
        capabilities: scope.capabilities,
      },
      ...(c.deployment
        ? {
            deployment: {
              id: String(c.deployment.id ?? ""),
              status: str(c.deployment.status),
              status_in_scope: str(c.deployment.status_in_scope),
              release_id: str(c.deployment.release_id ?? c.deployment.releaseId),
              created_at: str(c.deployment.created_at),
            },
          }
        : {}),
      ...(c.release
        ? {
            release: {
              id: String(c.release.id ?? ""),
              semver: str(c.release.semver),
              build_id: str(c.release.build_id ?? c.release.buildId),
              application_id: str(c.release.application_id),
            },
          }
        : {}),
    };
  },

  async scope(ctx: Api, id: string): Promise<ScopeRecord> {
    const res = (await ctx.api.GET("/scope/{id}", { params: { path: { id: Number(id) } } })) as Answer;
    if (res.error || !res.data || String(res.data.id) !== String(id)) {
      throw new Error(`scope ${id} could not be read${res.error ? `: ${JSON.stringify(res.error).slice(0, 200)}` : ""}`);
    }
    const d = res.data;
    return { id: String(d.id), slug: str(d.slug), asset_name: str(d.asset_name), dimensions: d.dimensions, capabilities: d.capabilities };
  },

  async patchScope(ctx: Api, id: string, body: Record<string, unknown>): Promise<void> {
    const res = (await ctx.api.PATCH("/scope/{id}", { params: { path: { id: Number(id) } }, body: body as never })) as Answer;
    if (res.error) throw new Error(`scope ${id} refused the update: ${JSON.stringify(res.error).slice(0, 200)}`);
  },

  async deployments(ctx: Api, scopeId: string): Promise<DeploymentRecord[]> {
    const rows = await listAll(ctx, "/deployment", { scope_id: scopeId });
    return rows.map((d) => ({
      id: String(d.id),
      status: str(d.status),
      status_in_scope: str(d.status_in_scope),
      release_id: str(d.release_id ?? d.releaseId),
      created_at: str(d.created_at),
    }));
  },

  async release(ctx: Api, id: string): Promise<ReleaseRecord> {
    const res = (await ctx.api.GET("/release/{id}", { params: { path: { id: String(id) } } })) as Answer;
    if (res.error || !res.data) throw new Error(`release ${id} could not be read`);
    const r = res.data;
    return { id: String(r.id), semver: str(r.semver), build_id: str(r.build_id ?? r.buildId), application_id: str(r.application_id) };
  },

  async releases(ctx: Api, applicationId: string): Promise<ReleaseRecord[]> {
    const rows = await listAll(ctx, "/release", { application_id: applicationId });
    return rows.map((r) => ({ id: String(r.id), semver: str(r.semver), build_id: str(r.build_id ?? r.buildId), application_id: str(r.application_id) }));
  },

  async assets(ctx: Api, buildId: string): Promise<AssetRecord[]> {
    const rows = await listAll(ctx, "/asset", { build_id: buildId });
    return rows.map((a) => ({ id: str(a.id), name: str(a.name), type: str(a.type), url: str(a.url), build_id: str(a.build_id) }));
  },

  /** Appends a message to the deployment; false when the platform refused it (callers treat it as best effort). */
  async message(ctx: Api, deploymentId: string, level: Level, code: string, message: string): Promise<boolean> {
    try {
      const res = (await ctx.api.PATCH("/deployment/{id}", {
        params: { path: { id: String(deploymentId) } },
        body: { messages: [{ level, code, message, timestamp: Math.floor(Date.now() / 1000) }] } as never,
      })) as Answer;
      return !res.error;
    } catch {
      return false;
    }
  },
};

export type Platform = typeof platform;

// ─── Derived facts ────────────────────────────────────────────────────

const IN_PROGRESS = new Set([
  "creating",
  "creating_approval",
  "running",
  "waiting_for_instances",
  "switching_traffic",
  "finalizing",
  "rolling_back",
  "cancelling",
]);
const TERMINAL = new Set([
  "failed",
  "cancelled",
  "canceled",
  "rolled_back",
  "finalized",
  "deleted",
  "deleting",
  "creating_approval_denied",
]);

/**
 * The deployment of the scope, other than `current`, still rolling out: an
 * in-progress status, or the scope's candidate with a status that is not
 * terminal. Two overlapping rollouts would distribute two releases to the
 * same group and leave no clear deployment to finalize or roll back.
 */
export function activeRollout(deployments: DeploymentRecord[], current: string): DeploymentRecord | undefined {
  return deployments
    .filter((d) => d.id !== String(current))
    .filter((d) => IN_PROGRESS.has(d.status ?? "") || (d.status_in_scope === "candidate" && !TERMINAL.has(d.status ?? "")))
    .sort((a, b) => (a.created_at ?? "").localeCompare(b.created_at ?? "") || a.id.localeCompare(b.id))
    .pop();
}

/**
 * Where a rollback returns to: among the finalized deployments other than
 * `current`, the one still active in the scope, else the most recent one.
 */
export function previousDeployment(deployments: DeploymentRecord[], current: string): DeploymentRecord | undefined {
  const finalized = deployments.filter((d) => d.status === "finalized" && d.id !== String(current));
  const active = finalized.find((d) => d.status_in_scope === "active");
  if (active) return active;
  return finalized.sort((a, b) => (a.created_at ?? "").localeCompare(b.created_at ?? "") || a.id.localeCompare(b.id)).pop();
}
