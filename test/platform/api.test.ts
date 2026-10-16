import { describe, expect, test } from "bun:test";
import { activeRollout, previousDeployment, type DeploymentRecord } from "../../src/platform/api";

const d = (id: string, status: string, status_in_scope = "inactive", created_at = `2025-12-${id.padStart(2, "0")}T00:00:00Z`): DeploymentRecord => ({ id, status, status_in_scope, created_at });

describe("another rollout in progress", () => {
  test("is a deployment other than the current one with an in-progress status", () => {
    expect(activeRollout([d("77", "creating", "candidate"), d("70", "finalized", "active"), d("75", "running")], "77")?.id).toBe("75");
    expect(activeRollout([d("77", "creating", "candidate"), d("70", "finalized", "active")], "77")).toBeUndefined();
  });
  test("or the scope's candidate with a status that is not terminal; terminal candidates never block", () => {
    expect(activeRollout([d("77", "creating"), d("76", "creating_approval", "candidate")], "77")?.id).toBe("76");
    for (const status of ["failed", "cancelled", "canceled", "rolled_back", "finalized", "deleted", "deleting", "creating_approval_denied"]) {
      expect(activeRollout([d("77", "creating"), d("76", status, "candidate")], "77")).toBeUndefined();
    }
  });
  test("the most recent one is named when several are", () => {
    expect(activeRollout([d("77", "creating"), d("71", "running"), d("73", "switching_traffic")], "77")?.id).toBe("73");
  });
});

describe("the previous deployment", () => {
  test("is the finalized one still active in the scope, else the most recent finalized one, never the current", () => {
    expect(previousDeployment([d("77", "creating"), d("70", "finalized", "active"), d("72", "finalized")], "77")?.id).toBe("70");
    expect(previousDeployment([d("77", "creating"), d("66", "finalized"), d("72", "finalized")], "77")?.id).toBe("72");
    expect(previousDeployment([d("77", "finalized", "active"), d("65", "failed")], "77")).toBeUndefined();
  });
});
