# Mobile store

A nullplatform **scope** that publishes mobile app binaries (Android, iOS) to a
distribution channel: tester groups today (Firebase App Distribution), public
stores and enterprise stores as their layers land. The binary comes from the
application's CI as a release asset; the scope signs it if asked, applies the
approval gate, publishes it to the channel's group and records what it did on
the deployment.

The scope is a **package** on [`@nullplatform/plugin`](https://github.com/nullplatform/plugin-libraries):
the scope, its scope type and every lifecycle action are declared in code, each
action is one TypeScript function, and one `np package publish` registers all
of it. It talks to AWS through the AWS SDK and to Firebase through its REST API:
the worker image carries no `aws`, no `firebase`, no `np` CLI.

## Layout

```
src/
├── main.ts                 the worker: pkg.start()
├── package.ts              definePackage + the tracer
├── deps.ts                 the seams the tests replace (CLI, AWS, HTTP, platform, env)
├── scope/                  what the developer sets, and what the actions do
│   ├── schema.ts           platform · channel · rollout_percentage, typed and validated
│   ├── resources.ts        scope(): the specification, its type, the action bindings
│   ├── plans.ts            the trace plans: what each action is for, step by step, in stages
│   └── actions/
│       ├── deployment.ts   start-initial, start-blue-green, switch-traffic, finalize, rollback, delete-deployment
│       ├── scope.ts        create-scope, update-scope, delete-scope
│       └── instances.ts    instance:data — the releases of the channel
├── platform/               what nullplatform knows
│   ├── api.ts              scopes, deployments, releases, assets, deployment messages; rollout rules
│   ├── configuration.ts    the "Mobile store" scope configuration and the IAM provider, per dimensions
│   ├── assets.ts           which asset of a release is each platform's binary (asset names)
│   └── workdir.ts          the scratch directories
├── layers/                 the four layers, one directory each, same names as before
│   ├── binaries/           download each platform's binary and check it is an APK or an IPA
│   ├── signing/            prebuilt (CI-signed) · keyvault (apksigner + keystore from Secrets Manager)
│   ├── distribution/
│   │   └── firebase/       setup · distribute (upload, operation, notes, group) · releases · token
│   └── gate/               policy (fail closed) · none
└── support/
    ├── aws.ts              STS assume-role, S3, Secrets Manager; the role the scope assumes
    └── cli.ts              spawn a tool (apksigner), redact secrets from its output
test/                       mirrors src/: scope/, platform/, layers/, with helpers.ts as the harness
provider/                   the scope configuration's provider specification (POST body)
requirements/aws/           OpenTofu module: the IAM role the scope assumes
```

| Action | What it does |
|---|---|
| `create-scope` / `update-scope` | Resolves the scope configuration for the scope's dimensions, checks the layers are implemented, and gives the scope an **asset name** if it has none. |
| `start-initial` | Resolve the release → assume the role → resolve the binaries → download → sign → set up Firebase → gate → publish; records `MOBILE_STORE_DISTRIBUTION` on the deployment. |
| `start-blue-green` | The same, refused while another deployment of the scope is still rolling out. |
| `switch-traffic` / `finalize-blue-green` | Firebase has no staged rollout: the weight is acknowledged and `MOBILE_STORE_ROLLOUT` recorded. |
| `rollback-deployment` | Firebase cannot unpublish: the previous release's binaries are distributed again (`MOBILE_STORE_ROLLBACK`). |
| `delete-deployment` | Removes the deployment's scratch directory, for every status, failed included. |
| `delete-scope` | Nothing to remove. |
| `instance:data` | The latest releases of each platform's Firebase app. |

Every action narrates itself on the trace: what each step did, with the facts
in it (which release and commit, which asset, which Firebase release and group),
and why; links to the release in the Firebase console and its testing page.

## What the developer configures

| Attribute | | |
|---|---|---|
| `platform` | `android` (default), `ios`, `both` | which binaries the scope publishes; only editable on create |
| `channel` | `internal` (default), `testers`, `production` | who receives each deployment: the Firebase tester **group alias** must exist with that name |
| `rollout_percentage` | 1–100, default 5 | for channels with a staged rollout; Firebase ignores it (always 100%) |

The asset type is `bundle`: the CI registers one asset per binary (see
[Asset names](#asset-names)).

## Platform setup

### The scope configuration

Everything else comes from the **"Mobile store" scope configuration**
(provider category `scope-configurations`, slug `mobile-store`), registered
once per account, namespace or dimension. Register its specification, then
create the configuration in the console or with `np provider create`:

```bash
np provider specification create --body @provider/mobile-store-configuration.json   # set visible_to to your NRN first
```

| Field | |
|---|---|
| `signing_layer` | `prebuilt` (the CI signs) · `keyvault` (apksigner with a keystore from Secrets Manager; Android only, needs a worker image with the build-tools) · `match` (declared, not implemented) |
| `distribution_layer` | `firebase` · `app-store`, `google-play`, `foundry-eas`, `intune` (declared, not implemented) |
| `gate_layer` | `none` · `store-review` (declared, not implemented) |
| `firebase.project`, `firebase.app_id_android`, `firebase.app_id_ios`, `firebase.credentials_secret` | the Firebase project, the apps, and the **name** of the Secrets Manager secret holding the service account JSON (Firebase App Distribution Admin) |
| `android.keystore_secret` | for `keyvault`: the secret with `{keystore_base64, keystore_password, key_alias, key_password}` |
| `assets.bucket`, `assets.region` | where the CI uploads the binaries |

Secrets must live under the `mobile/` prefix: it is what the scope's IAM policy
allows, and the worker refuses any other name. The gate policy fails closed:
production on a public store requires `store-review`; on Firebase it is
allowed without a gate, with a warning on the deployment.

### The role

The worker assumes the IAM role the platform's **identity provider**
(category `identity-access-control`) names for selector `mobile-store`
(`iam_role_arns.arns[]`), so the agent's own role stays narrow: read the assets
bucket, read the `mobile/*` secrets. `requirements/aws` is the OpenTofu module
that creates it. Overrides, for a developer's machine: `MOBILE_STORE_ASSUME_ROLE_ARN`
(`none` keeps the credentials already in the environment),
`MOBILE_STORE_ASSUME_ROLE_ARN_DEFAULT`, `MOBILE_STORE_ASSUME_ROLE_SELECTOR`.

### Asset names

The scope's `asset_name` decides which asset of a release is deployed. The
platform picks the asset with that name from the release and rejects a
deployment of a scope without one. The CI registers one asset per binary and
the scope points at the one it deploys:

- The first platform of the scope (`android` for `android` and `both`, `ios`
  for `ios`) deploys exactly `asset_name`.
- A scope with both platforms deploys, for iOS, the same name with the prefix
  swapped: `android-internal` → `ios-internal`, `android` → `ios`. Any other name
  (`mobile-prod`, `androidtv-prod`) cannot be derived and the action fails,
  saying how to fix it (`np scope patch --id <id> --body '{"asset_name":"android"}'`).
- `create-scope` / `update-scope` set `asset_name` to the first platform when the
  scope has none (what scopes created through the API get) and validate it
  when set.

The recommended setup is one binary per platform named after the platform
(`android`, `ios`), with no environment in the name: every scope deploys the
same binary and the environment dimension only selects the scope configuration.
Put the environment in the name only when the binary embeds environment
configuration at build time; then each scope's `asset_name` points at its own.

## Run locally as a package

```bash
mise trust && mise run test        # 83 tests, in-process, no network
mise run describe                  # the manifest np package publish sends
export NP_API_KEY=...              # an agent key
eval "$(aws configure export-credentials --format env)"
MOBILE_STORE_ASSUME_ROLE_ARN=none np package run    # or: mise run run
```

`np package run` builds `mobile-store-worker:dev`, starts a local
controlplane-agent tagged `package:mobile-store,local:<user>` that spawns the
worker, and forwards your shell's environment to it (your AWS keys included;
`MOBILE_STORE_ASSUME_ROLE_ARN=none` tells the scope to use them as they are).
Point a notification channel at `local:<user>` to route a scope's actions to
your machine. **Never start a local agent with tags a production channel
selects.**

## Publish

```bash
np package publish --nrn <nrn> --image <registry>/<repo>@sha256:<digest>
```

registers the scope specification, its type, every action specification and
the package revision at `<nrn>`. The release workflow builds and pushes the
image to ECR Public on every merge to `main` (`feat:` / `fix:` commits,
release-please) and registers it as a nullplatform artifact; pull requests push
a beta image.

## Operator settings (worker environment)

| Variable | Default | |
|---|---|---|
| `MOBILE_STORE_WORKDIR` | `/tmp/mobile-store` in the image | scratch directories, one per deployment |
| `MOBILE_STORE_ASSUME_ROLE_*` | | see [The role](#the-role) |
| `SIGNING_LAYER`, `DISTRIBUTION_LAYER`, `GATE_LAYER`, `ASSETS_BUCKET`, `ASSETS_REGION` | | stand in for a missing scope configuration |
| `FIREBASE_APP_DISTRIBUTION_URL` | Google's | the App Distribution API origin, as for the firebase CLI |
| `NP_TRACING_URL` | set by the agent | the trace every action narrates on |

## CI

| Workflow | When | What |
|---|---|---|
| branch-validation | PR | branch named `feat/…`, `fix/…`, `chore/…` |
| conventional-commit | PR | commit messages (release-please reads them) |
| trivy | PR | IaC misconfiguration and image scan |
| beta | PR | publishes `beta/<image>:test-<branch>-<short sha>` and registers it as an artifact |
| release | push to `main` | release-please → ECR Public → nullplatform artifact → GitHub release |
