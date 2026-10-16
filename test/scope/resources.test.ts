import { describe, expect, test } from "bun:test";
import pkg from "../../src/package";
import { plans, STEP } from "../../src/scope/plans";

describe("the manifest", () => {
  const m = pkg.manifest() as any;
  const component = (type: string) => m.components.find((c: any) => c.resource_type === type);
  const spec = component("service_specification").resource;

  test("publishes the scope, its type, every lifecycle action and the instance listing", () => {
    expect(m).toMatchObject({ name: "mobile-store", slug: "mobile-store" });
    expect(spec).toMatchObject({
      name: "Mobile store",
      type: "scope",
      selectors: { category: "Scope", provider: "Agent", sub_category: "Mobile store", imported: false },
      telemetry: { instances: true },
    });
    expect(spec.action_specifications.map((a: any) => a.slug).sort()).toEqual(
      [
        "create-scope",
        "update-scope",
        "delete-scope",
        "delete-deployment",
        "start-initial",
        "start-blue-green",
        "switch-traffic",
        "finalize-blue-green",
        "rollback-deployment",
        "instance:data",
      ].sort(),
    );
    expect(spec.attributes.schema.properties.asset_type.default).toBe("bundle");
    expect(spec.attributes.schema.uiSchema.elements).toHaveLength(3);
    expect(component("scope_type").resource).toMatchObject({ name: "Mobile store", type: "custom" });
  });
});

describe("the plans tell the story", () => {
  type Spec = { title: string; description: string; groups: Array<{ key: string; title: string }>; steps: Array<{ key: string; title: string; description: string; group: string }> };
  const of = (slug: string): Spec => (plans as Record<string, Spec>)[slug];

  test("every action has a title and an intent, every step a title and what it does, in a declared stage", () => {
    for (const slug of Object.keys(plans)) {
      const p = of(slug);
      expect(p.title.length, slug).toBeGreaterThan(0);
      expect(p.description.length, slug).toBeGreaterThan(0);
      const stages = new Set(p.groups.map((g) => g.key));
      for (const step of p.steps) {
        expect(step.title.length, `${slug}/${step.key}`).toBeGreaterThan(0);
        expect(step.description.length, `${slug}/${step.key}`).toBeGreaterThan(0);
        expect(stages.has(step.group), `${slug}/${step.key}`).toBe(true);
      }
    }
  });
  test("a publish runs the layers in order; blue-green checks the rollout first; a rollback resolves the previous release", () => {
    const keys = (slug: string) => of(slug).steps.map((s) => s.key);
    expect(keys("start-initial")).toEqual(["resolve context", "assume role", "resolve assets", "download binaries", "sign", "setup distribution", "gate", "publish"]);
    expect(keys("start-blue-green")[0]).toBe(STEP.checkActiveRollout.key);
    expect(keys("rollback-deployment")).toContain("resolve previous assets");
    expect(keys("rollback-deployment")).not.toContain("gate");
    expect(keys("switch-traffic")).toEqual(["resolve context", "record rollout state"]);
    expect(keys("delete-deployment")).toEqual(["remove scratch directory"]);
    expect(keys("create-scope")).toEqual(["resolve configuration", "ensure asset name"]);
  });
});
