mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/mock-policy"
    }
  }
}

variables {
  cluster_name       = "test-cluster"
  assets_bucket_name = "assets-test-mobile"
}

run "default_role_name" {
  command = apply

  assert {
    condition     = aws_iam_role.nullplatform_mobile_store[0].name == "nullplatform_test-cluster_mobile_store_role"
    error_message = "the role name must default to nullplatform_<cluster>_mobile_store_role"
  }

  assert {
    condition     = output.role_name == "nullplatform_test-cluster_mobile_store_role"
    error_message = "role_name must expose the role name"
  }

  assert {
    condition     = output.permissions_role_arn == "arn:aws:iam::123456789012:role/mock-role"
    error_message = "permissions_role_arn must expose the role ARN"
  }

  assert {
    condition     = aws_iam_policy.nullplatform_mobile_store[0].name == "nullplatform_test-cluster_mobile_store_policy"
    error_message = "the policy name must default to nullplatform_<cluster>_mobile_store_policy"
  }

  assert {
    condition     = jsondecode(aws_iam_role.nullplatform_mobile_store[0].assume_role_policy).Statement[0].Principal.AWS == ["arn:aws:iam::123456789012:role/nullplatform-test-cluster-agent-role"]
    error_message = "the role must trust the derived agent role"
  }
}

run "least_privilege_policy" {
  command = apply

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_policy.nullplatform_mobile_store[0].policy).Statement :
      !contains(flatten([s.Resource]), "*")
    ])
    error_message = "no statement may use Resource = \"*\""
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_policy.nullplatform_mobile_store[0].policy).Statement :
      endswith(s.Resource, "secret:mobile/*") if startswith(s.Sid, "SecretsManager")
    ])
    error_message = "the secrets resource must end in secret:mobile/*"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_policy.nullplatform_mobile_store[0].policy).Statement :
      s.Resource if startswith(s.Sid, "SecretsManager")
    ] == ["arn:aws:secretsmanager:us-east-1:123456789012:secret:mobile/*"]
    error_message = "the secrets resource must use the current region and account"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_policy.nullplatform_mobile_store[0].policy).Statement :
      s.Resource if startswith(s.Sid, "S3")
    ] == ["arn:aws:s3:::assets-test-mobile/*", "arn:aws:s3:::assets-test-mobile"]
    error_message = "the S3 statements must point at the assets bucket and its objects"
  }

  assert {
    condition = sort(flatten([
      for s in jsondecode(aws_iam_policy.nullplatform_mobile_store[0].policy).Statement : s.Action
    ])) == sort(["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation", "secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"])
    error_message = "the policy must grant exactly the read actions the scope needs"
  }
}

run "custom_secrets_prefix" {
  command = plan

  variables {
    secrets_prefix = "apps/mobile/"
  }

  assert {
    condition     = local.secrets_prefix_arn == "arn:aws:secretsmanager:us-east-1:123456789012:secret:apps/mobile/*"
    error_message = "the secrets resource must follow secrets_prefix"
  }
}

run "no_role_when_disabled" {
  command = apply

  variables {
    iam_create_role = false
  }

  assert {
    condition     = length(aws_iam_role.nullplatform_mobile_store) == 0 && length(aws_iam_policy.nullplatform_mobile_store) == 0 && length(aws_iam_role_policy_attachment.mobile_store) == 0
    error_message = "iam_create_role = false must create nothing"
  }

  assert {
    condition     = output.permissions_role_arn == "" && output.role_name == ""
    error_message = "the outputs must be empty when nothing is created"
  }
}

run "rejects_invalid_bucket_name" {
  command = plan

  variables {
    assets_bucket_name = "Assets_Bucket/*"
  }

  expect_failures = [var.assets_bucket_name]
}

run "rejects_wildcard_secrets_prefix" {
  command = plan

  variables {
    secrets_prefix = "*"
  }

  expect_failures = [var.secrets_prefix]
}
