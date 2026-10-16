import { describe, expect, test } from "bun:test";
import { attributes, platformsOf, schema, uiSchema } from "../../src/scope/schema";

const ctx = (params: Record<string, unknown>) => ({ params }) as any;

describe("the developer's attributes", () => {
  test("default to android, internal, 5%", () => {
    expect(attributes(ctx({}))).toEqual({ platform: "android", platforms: ["android"], channel: "internal", rolloutPercentage: 5 });
  });
  test("both platforms list android first: it names the scope's asset", () => {
    expect(attributes(ctx({ platform: "both", channel: "testers", rollout_percentage: "20" })).platforms).toEqual(["android", "ios"]);
    expect(platformsOf("ios")).toEqual(["ios"]);
  });
  test("refuse what the schema does not offer, naming the fix", () => {
    expect(() => attributes(ctx({ platform: "web" }))).toThrow(/android, ios or both/);
    expect(() => attributes(ctx({ channel: "vip" }))).toThrow(/internal, testers or production/);
    expect(() => attributes(ctx({ rollout_percentage: 0 }))).toThrow(/between 1 and 100/);
    expect(() => attributes(ctx({ rollout_percentage: "many" }))).toThrow(/between 1 and 100/);
  });
  test("the console form shows exactly the required inputs, each with a default", () => {
    expect(schema.required).toEqual(["platform", "channel", "rollout_percentage"]);
    for (const key of schema.required) expect((schema.properties as any)[key].default).toBeDefined();
    expect(uiSchema.elements.map((e) => e.scope as string)).toEqual(schema.required.map((k) => `#/properties/${k}`));
  });
});
