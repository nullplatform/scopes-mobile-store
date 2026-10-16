# requirements/aws

AWS IAM the mobile-store scope needs to operate under the **assume-role** pattern,
consumed as an OpenTofu module by the implementation stack (same shape as the
static-files scope requirements).

It creates a dedicated **permissions role** that the nullplatform agent assumes
(`sts:AssumeRole`) plus one least-privilege policy:

- `s3:GetObject` on `arn:aws:s3:::<assets_bucket_name>/*`, and `s3:ListBucket` +
  `s3:GetBucketLocation` on the bucket itself: the scope reads the binary the CI uploaded.
- `secretsmanager:GetSecretValue` + `secretsmanager:DescribeSecret` on
  `arn:aws:secretsmanager:<region>:<account>:secret:<secrets_prefix>*`: the scope reads
  the distribution credentials (e.g. `firebase.credentials_secret`). Region and account
  come from the provider the module runs with, so the secrets must live in that region.

The role's ARN is wired into the agent (`assume_role_arns`).

## Usage (implementation-aws)

```hcl
module "scope_requirements_mobile_store" {
  source = "git::https://github.com/nullplatform/scopes-mobile-store.git//requirements/aws?ref=<tag>"

  cluster_name       = module.eks.eks_cluster_name
  agent_role_arn     = local.agent_role_arn
  assets_bucket_name = aws_s3_bucket.assets_mobile.bucket
}

module "agent_iam" {
  # ...
  assume_role_arns = [
    # ...
    module.scope_requirements_mobile_store.permissions_role_arn,
  ]
}
```

## Variables

| Variable | Default | Description |
|---|---|---|
| `cluster_name` | (required) | Cluster name; derives default resource names. |
| `assets_bucket_name` | (required) | Bucket the CI uploads the binaries to (the scope configuration's `assets.bucket`). |
| `secrets_prefix` | `mobile/` | Secrets Manager name prefix the scope may read. |
| `agent_role_arn` | `""` → derived | Agent role trusted to assume this role. Empty derives `nullplatform-<cluster>-agent-role`. |
| `additional_agent_role_arns` | `[]` | Extra trusted principals. |
| `role_name` | `""` → `nullplatform_<cluster>_mobile_store_role` | Override for the role name. |
| `policies_name_prefix` | `""` → `nullplatform_<cluster>` | Override for the policy name prefix. |
| `iam_create_role` | `true` | When false, the module creates nothing. |
| `iam_resource_tags_json` | `{}` | Tags applied to IAM resources. |

## Outputs

`permissions_role_arn`, `role_name`.

## Tests

```bash
tofu init -backend=false && tofu test   # or: make test-tofu MODULE=mobile-store
```

## Versioning

Point the module `source` at a **tag** that contains this module, never a branch.
