# scopes-mobile-store

nullplatform scope that publishes mobile app binaries (Android, iOS) to a distribution channel: tester groups (Firebase App Distribution), public stores (App Store, Google Play) or an enterprise store. Generic by design: the binary comes from the application's CI as an asset; the scope signs it if asked, publishes it to the channel of the dimension and tracks the rollout. Built on the `scopes-*` template; the sections below are the template's operating notes.

## Start here

1. Done: the module is `mobile-store/` and the display name is "Mobile store".
2. Add the **Public ECR** service to the application in nullplatform. It creates the ECR Public repository and the publisher role; then set the secret and variable in [Publishing](#publishing).
3. Write your steps in `<slug>/scripts/` and wire them in `<slug>/<entity>/workflows/*.yaml`; define the capabilities developers choose in `<slug>/specs/service-spec.json.tpl` and operator settings in `<slug>/values.yaml`.
4. Merge to `main` with a `feat:` or `fix:` commit: release-please opens the release PR, and merging it publishes the image and the package.

## Layout

```
entrypoint              agent calls it; routes deployment actions to service/deployment, the rest to service/scope
service/                scope, deployment and instance handlers (map an action to its workflow) and the shared runner
mobile-store/
  scope/workflows/      create, update (check the scope configuration and its layers, set the asset name), delete (no-op)
  deployment/workflows/ initial, blue_green, switch_traffic, finalize, rollback, delete
  instance/workflows/   list: answers instance:data with the releases of the distribution channel
  deployment/scripts/   build_context, run_platforms, layer_executor, do_publish, do_rollback,
                        check_active_rollout, record_rollout_state, delete_deployment, ensure_asset_name
                        and shared helpers (asset_names: which asset of a release each platform deploys)
  deployment/platform/  android, ios: download and validate the binary of the release
  deployment/signing/   prebuilt (CI-signed), keyvault (apksigner with a keystore from the secrets manager)
  deployment/distribution/ firebase: setup, publish, rollback (re-distributes the previous release), list_releases
  deployment/gate/      none: no external approval
  deployment/tests/     BATS tests of every script and layer, with the CLI mocks (np, aws, firebase, apksigner, curl)
  utils/                assume_role_step: assumes the scope IAM role (identity-access-control provider, selector mobile-store)
  scripts/              no_op (delete-scope)
  specs/                service-spec, scope-type-definition, notification-channel and actions/*.json.tpl
  values.yaml           operator configuration for the workflows
Dockerfile              worker image on the shared worker-bridge base
mise.toml               run it on your machine as a package (`np package run`)
```

| Action | Workflow |
|---|---|
| `create-scope` / `update-scope` / `delete-scope` | `scope/workflows/{create,update,delete}.yaml` |
| `start-initial` / `start-blue-green` | `deployment/workflows/{initial,blue_green}.yaml` |
| `switch-traffic` / `finalize-blue-green` / `rollback-deployment` | `deployment/workflows/{switch_traffic,finalize,rollback}.yaml` |
| `delete-deployment` | `deployment/workflows/delete.yaml` (it must also clean up `failed` deployments) |
| any other slug `foo` | `scope/workflows/foo.yaml`, or `deployment/workflows/foo.yaml` when it carries a `deployment_id` |

A new action needs its `specs/actions/<slug>.json.tpl`, its slug in `available_actions`, and the workflow. Every `--overrides-path` directory can hold `<entity>/workflows/<action>.yaml` to layer steps on top of the base workflow.

`instance:data` runs `instance/workflows/list.yaml` (`service/instance/entrypoint`): it lists the releases of the distribution channel and prints only JSON (its first step sends every log to stderr). Logs, metrics and parameters are not implemented: `log:read` and `metric:*` answer empty results, and `parameter:*` fails. To serve one, add `<slug>/<entity>/workflows/` and route it in `entrypoint` (see the `k8s` scope in [nullplatform/scopes](https://github.com/nullplatform/scopes)); their steps must print only JSON.

The engine (`np service workflow exec`) sources every step of a workflow in one `bash -c`, joined by `&&`: what a step exports reaches the next steps, the first step that fails stops the workflow, and a step's `configuration` only applies to that step. `output:` is informative only (the engine ignores it): steps list what they export there, and `deployment/tests/workflows/` checks that every variable a step consumes is declared by an earlier one. `set -e` does not apply inside steps chained with `&&` (only in the last one), so the scripts check each failure and `return 1` explicitly. Keep step `configuration` values to one word (older CLIs splice them unquoted).

## Asset names

The scope's `asset_name` decides which asset of a release is deployed. nullplatform picks the asset with that name from the release (and passes it as `CONTEXT.asset`); the platform rejects a deployment of a scope without one, with a misleading 400. The CI registers one asset per binary and the scope points at the one it deploys:

- The first platform of the scope (`android` for `android` and `both`, `ios` for `ios`) deploys exactly `asset_name`.
- A scope with both platforms deploys, for iOS, the same name with the platform prefix swapped: `android-internal` → `ios-internal`, `android` → `ios`. Any other name (`mobile-prod`, `androidtv-prod`, `android2`) cannot be derived and the deployment fails asking for `android` or `android-<suffix>`.
- Names must match `^[a-z0-9][a-z0-9._-]*$`.
- When the context does not carry `asset_name`, the scope is read with `np scope read`; a scope without one deploys its first platform, but a read that fails (or answers anything but that scope) fails the action instead of guessing the binary.
- `create-scope` and `update-scope` set `asset_name` to the first platform (`android` or `ios`) when the scope has none, which is what scopes created through the API get, and validate it when it is set. `np scope patch --id <scope id> --body '{"asset_name":"android-internal"}'` changes it.

The default, and the recommended setup, is one binary per platform named after the platform (`android`, `ios`), with no environment in the name: every scope deploys the same binary and the environment dimension only selects the scope configuration (signing, distribution channel). A suffix is fine when the CI ships more than one flavour of the app (`android-internal` → `ios-internal`). The exception is a binary that embeds environment configuration at build time, as with Volt MX Iris: there the CI builds one binary per environment, names each asset after it, and each scope's `asset_name` points at its own. The rollback resolves the previous release's binary with the same rule (`deployment/scripts/asset_names`).

## Install in your organization

The scope is published once as the package `np-mobile-store` (scope type "Mobile store"), visible to every organization. You do not copy its specs: you install the package and use it read-only.

How installing a package works, how it coexists with a copy you registered, how to upgrade, and when to fork instead are in the [package installation guide](https://docs.nullplatform.com/docs/packages/install); this section has what is specific to this scope.

Already registered a copy with tofu-modules' `scope_definition` from your infrastructure repository? It keeps working: it registered specs that stay in every release, and the package installs next to it, as the guide explains.

Installing it touches the same three layers as registering a scope yourself, and only the nullplatform layer changes:

| Layer | What | Module |
|---|---|---|
| infrastructure (cloud credentials) | The permissions role the agent assumes: read of the assets bucket and of the `mobile/*` secrets | [`mobile-store/specs/requirements/aws`](./mobile-store/specs/requirements/aws) |
| nullplatform (nullplatform API key) | The installation of the package, the scope type, the NRN settings and the scope-configuration schema | tofu-modules' `scope_package_installation` |
| bindings | The agent channel, the role under selector `mobile-store` in your IAM provider, and the scope's settings | tofu-modules' `scope_definition_agent_association`, your providers |

Pick ONE release of this repository (the latest is on its [releases page](https://github.com/nullplatform/scopes-mobile-store/releases)) and use its version in every place below: the IAM role is the one the worker of that same release expects.

```hcl
# ── infrastructure layer ─────────────────────────────────────────────
module "mobile_store_requirements" {
  source = "git::https://github.com/nullplatform/scopes-mobile-store.git//mobile-store/specs/requirements/aws?ref=vX.Y.Z"

  cluster_name       = "my-cluster" # names the role nullplatform_my-cluster_mobile_store_role
  agent_role_arn     = module.agent_iam.nullplatform_agent_role_arn
  assets_bucket_name = aws_s3_bucket.assets_mobile.bucket
}

# The agent role must be allowed to assume it: add it to the assume_role_arns
# of tofu-modules' infrastructure/aws/iam/agent.
#   assume_role_arns = [..., module.mobile_store_requirements.permissions_role_arn]

# ── nullplatform layer ───────────────────────────────────────────────
module "mobile_store" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/scope_package_installation?ref=v9.16.0"

  nrn             = var.nrn
  np_api_key      = var.np_api_key # for the NRN settings patch (np nrn patch)
  package_slug    = "np-mobile-store"
  package_version = "X.Y.Z" # the same release, without the v

  # Yours, created from this repository's templates at the same release:
  service_spec_name                = "Mobile store" # the scope type developers pick
  service_spec_description         = "Publishes mobile app binaries (Android, iOS) to a distribution channel: tester groups, app stores or an enterprise store"
  service_path                     = "mobile-store"
  repository_scope_template        = "https://raw.githubusercontent.com/nullplatform/scopes-mobile-store/refs/tags"
  repository_scope_template_branch = "vX.Y.Z" # the same release
  create_scope_configuration       = true
  create_agent_channel             = false # the channel lives in your bindings layer, below
}

# ── bindings layer ───────────────────────────────────────────────────
# mobile_store_requirements and mobile_store come from the other layers (remote state).
module "mobile_store_channel" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/scope_definition_agent_association?ref=v9.16.0"

  nrn                      = var.nrn
  tags_selectors           = { cluster = "runtime" } # must match the agent's TAGS
  scope_specification_id   = local.mobile_store.service_specification_id
  scope_specification_slug = local.mobile_store.service_specification_slug
  service_path             = "mobile-store"

  # The channel template, from the same tag
  repository_notification_channel        = "https://raw.githubusercontent.com/nullplatform/scopes-mobile-store/refs/tags"
  repository_notification_channel_branch = "vX.Y.Z" # the same release

  worker_orchestrator = true
  package_slug        = local.mobile_store.package_slug
}

# The scope's settings, in a provider of the schema the installation created:
# the layer of each phase and what it needs (every key is in
# mobile-store/specs/scope-configuration.json.tpl).
resource "nullplatform_provider_config" "mobile_store_configuration" {
  nrn  = var.nrn
  type = local.mobile_store.scope_configuration_specification_slug
  attributes = jsonencode({
    signing_layer      = "prebuilt"  # or keyvault
    distribution_layer = "firebase"
    gate_layer         = "none"
    assets             = { bucket = aws_s3_bucket.assets_mobile.bucket }
    firebase = {
      project            = "my-firebase-project"
      app_id_android     = "1:123456789012:android:abcdef"
      app_id_ios         = "1:123456789012:ios:abcdef"
      credentials_secret = "mobile/firebase-service-account" # under the requirements module's secrets_prefix
    }
  })
}

# One aws-iam-configuration per NRN and dimensions: add the entry to the list
# your IAM provider already has.
#   { selector = "mobile-store", arn = local.mobile_store_requirements.permissions_role_arn }
```

The scope assumes the role it finds under selector `mobile-store` in the IAM provider closest to its NRN. To upgrade, move the release in every layer: `ref` of the requirements module, `package_version` and `repository_scope_template_branch` of the installation and `repository_notification_channel_branch` of the channel. See tofu-modules' [`scope_package_installation`](https://github.com/nullplatform/tofu-modules/tree/main/nullplatform/scope_package_installation) for its inputs and outputs.

Prerequisites: an agent whose `TAGS` match the channel's `tags_selectors`, with `np-mobile-store` in its `worker_orchestrated_packages` and `public.ecr.aws/nullplatform/*` in `worker.allowedRegistries`.

Every release publishes the new revision from this repository ([`mobile-store/publish`](./mobile-store/publish), a stack on tofu-modules' `scope_package_publish`, applied by the `publish-package` job of the release workflow).

## Run locally as a package

`np package run` runs this scope on your machine the way production does: a
local controlplane-agent that registers with the platform, spawns the worker
image built from this repo, and hands it every action routed to it. No cluster,
no publish. The two tasks in `mise.toml` are the whole contract with the CLI:

| Command | Runs | Does |
|---|---|---|
| `np package build --image` | `mise run build:image` | Builds `mobile-store-worker:dev` |
| `np package run` | `mise run run` | Builds the image, then starts the local agent |

Prerequisites: **Docker** with host networking (Linux as is; on Docker Desktop
enable *host networking*), **[mise](https://mise.jdx.dev)** (`mise trust` once
here), an **`NP_API_KEY`** for the agent to register with, and `np` from the
**alpha** channel, which carries `np package run`:

```bash
curl -fsSL https://cli.nullplatform.com/install.sh | VERSION=alpha sh   # ~/.local/bin/np
np package run --help                                                   # must list --no-forward-env
```

```bash
export NP_API_KEY=...
eval "$(aws configure export-credentials --format env)"   # cloud credentials as variables
np package run --log-level DEBUG                          # Ctrl+C to stop
```

The agent is tagged `package:mobile-store` and `local:<your user>`. It receives an
action only when the scope's notification channel selects those tags, so
point a channel at `local:<your user>` to route work to your machine.

> **Tags decide who gets the work.** Never start a local agent with tags a
> production channel selects: it would receive production actions.

`np package run` forwards your shell's environment to the agent container,
minus what describes your machine (`PATH`, `HOME`, `DOCKER_*`, `KUBECONFIG`,
`AWS_PROFILE` and the other file-pointing AWS variables), and the `run` task
passes the same variables to the worker through an `NP_WORKER_RULES` entry.
Every secret in your shell crosses too, and is readable with `docker inspect`;
pass `--no-forward-env` to forward nothing.

| Variable | Default | Purpose |
|---|---|---|
| `NP_API_KEY` | required | The key the agent registers with (`--api-key` also sets it) |
| `NP_LOG_LEVEL` | `INFO` | Agent log level (`--log-level` also sets it) |
| `NP_PACKAGE_SLUG` | `mobile-store` | The slug in the `package:<slug>` tag, when published under another slug |
| `NP_LOCAL_USER` | `$USER` | The value of the `local:<user>` tag |
| `NP_AGENT_IMAGE` | `controlplane-agent:latest` | The agent image; needs worker rules (0.11.1+) |

The local run never changes what the platform runs. To ship the change, merge
it: the release publishes the image and registers the artifact.

## CI

| Workflow | When | What |
|---|---|---|
| branch-validation | PR | branch named `feat/…`, `fix/…`, `chore/…` |
| conventional-commit | PR | commit messages (release-please reads them) |
| shellcheck | PR | every bash script |
| trivy | PR | IaC misconfiguration and image scan, to the Security tab |
| beta | PR (opened, push, reopened) | publish-test-image-oci: pushes `beta/<image>:test-<branch>-<short sha>` and registers it as a nullplatform artifact |
| release | push to `main` | release-please → build and push `vX.Y.Z` and `latest` to ECR Public → nullplatform artifact → the package revision (`mobile-store/publish`) → GitHub release |
| auto-merge-release | after release | merges the release PR |
| dependabot | daily / weekly | base image and shared workflow bumps |

## Image tags

| Image | Moved by | Use it to |
|---|---|---|
| `agent-plugins/scopes/<name>:vX.Y.Z` | its release, once | pin an exact version |
| `agent-plugins/scopes/<name>:latest` | each release | follow the last released version |
| `beta/agent-plugins/scopes/<name>:test-<branch>-<short sha>` | each push to a pull request of this repository | deploy a change to a test scope before merging it |

Beta images live in a separate repository that the beta role can write and the production role cannot, so a beta can never overwrite a released image. Pull requests from this repository can assume the beta role (fork and bot pull requests are skipped), and the tag carries the commit SHA, so two pull requests never overwrite each other by accident. Nothing deletes beta tags: they are ephemeral by convention. Each beta is also registered as its own nullplatform oci_image artifact (the `beta/` repository, under `NP_ARTIFACT_NRN`), separate from the release artifact, so it can be deployed to a test scope from the platform.

## Publishing

After adding the **Public ECR** service to the application, set in this repository:

| Name | Kind | Value |
|---|---|---|
| `AWS_ROLE_ARN_ECR_PUSH` | secret | the publisher role ARN the Public ECR service returns |
| `NP_ARTIFACT_NRN` | variable | the NRN of the organization that owns the artifacts |

`ARTIFACT_NP_API_KEY` comes from the organization, as do `PACKAGE_STATE_AWS_ACCOUNT_ID`, `PACKAGE_TFSTATE_BUCKET` and `PACKAGE_TFSTATE_REGION`, where the publish stack keeps its state (the state role is `github-actions-<repository>-package-state` in that account, by convention). The release checks all three before building and fails with a clear error if one is missing. Beta images assume the role in the organization secret `AWS_BETA_ROLE_ARN` (no role is written in the workflow) and push to the image's `beta/` repository in ECR Public, which the dispatcher creates together with the production one. In this template repository neither workflow runs.
