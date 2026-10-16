################################################################################
# Mobile-store scope — assume-role IAM
#
# The mobile-store scope reads the binary the CI uploaded to the assets bucket
# and the distribution credentials (e.g. the Firebase service account) from
# Secrets Manager. It does so via the ASSUME-ROLE pattern: this dedicated role
# holds the permissions and the nullplatform agent assumes it
# (sts:AssumeRole). The consuming stack passes this role's ARN to the agent
# (assume_role_arns).
#
# The role trusts the agent role BY NAME (derived default) rather than by a
# module output, so the consuming stack can wire the ARN back into the agent
# without creating a dependency cycle. The agent role name is the conventional
# "nullplatform-{cluster_name}-agent-role".
#
# Least privilege: read-only on one bucket and on the secrets under one prefix.
################################################################################

resource "aws_iam_role" "nullplatform_mobile_store" {
  count = local.iam_create ? 1 : 0

  name        = local.role_name
  description = "Permissions role assumed by the nullplatform agent role for the mobile-store scope"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = concat([local.agent_role_arn], var.additional_agent_role_arns) }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.iam_default_tags
}

resource "aws_iam_policy" "nullplatform_mobile_store" {
  count = local.iam_create ? 1 : 0

  name        = "${local.policies_name_prefix}_mobile_store_policy"
  description = "Policy for the mobile-store scope (read the assets bucket and the distribution secrets)"
  tags        = local.iam_default_tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3ReadBinaries"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${local.assets_bucket_arn}/*"
      },
      {
        Sid    = "S3ListAssetsBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = local.assets_bucket_arn
      },
      {
        Sid    = "SecretsManagerReadDistributionSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = local.secrets_prefix_arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "mobile_store" {
  count = local.iam_create ? 1 : 0

  role       = aws_iam_role.nullplatform_mobile_store[0].name
  policy_arn = aws_iam_policy.nullplatform_mobile_store[0].arn
}
