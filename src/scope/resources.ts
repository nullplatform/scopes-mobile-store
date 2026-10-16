/**
 * The scope: "Mobile store", a scope type that publishes mobile app binaries
 * to a distribution channel. The developer picks the platforms, the channel
 * and the rollout; the platform team's "Mobile store" scope configuration
 * says how (signing, distribution, gate, assets bucket). Every lifecycle
 * action is one function in ./actions; the plans in ./plans tell the trace
 * what each one is for.
 */

import { Actions, scope } from "@nullplatform/plugin/package";
import { deleteDeployment, finalizeBlueGreen, rollbackDeployment, startBlueGreen, startInitial, switchTraffic } from "./actions/deployment";
import { listInstances } from "./actions/instances";
import { createScope, deleteScope, updateScope } from "./actions/scope";
import { plans } from "./plans";
import { ASSET_TYPE, schema, uiSchema } from "./schema";

export { plans };

export const target = scope({
  slug: "mobile-store",
  name: "Mobile store",
  assignableTo: "any",
  selectors: { category: "Scope", provider: "Agent", subCategory: "Mobile store", imported: false },
  attributes: { schema },
  uiSchema,
  assetType: ASSET_TYPE,
  scopeType: {
    description: "Publishes mobile app binaries (Android, iOS) to a distribution channel: tester groups, app stores or an enterprise store",
  },
  telemetry: { instances: true },
  plans,
  actions: {
    [Actions.CREATE_SCOPE]: createScope,
    [Actions.UPDATE_SCOPE]: updateScope,
    [Actions.DELETE_SCOPE]: deleteScope,
    [Actions.DELETE_DEPLOYMENT]: deleteDeployment,
    [Actions.START_INITIAL]: startInitial,
    [Actions.START_BLUE_GREEN]: startBlueGreen,
    [Actions.SWITCH_TRAFFIC]: switchTraffic,
    [Actions.FINALIZE_BLUE_GREEN]: finalizeBlueGreen,
    [Actions.ROLLBACK_DEPLOYMENT]: rollbackDeployment,
    [Actions.INSTANCE_DATA]: listInstances,
  },
});
