output "permissions_role_arn" {
  description = "ARN of the mobile-store permissions role assumed by the nullplatform agent role. Pass it to the agent (assume_role_arns)."
  value       = local.iam_create ? aws_iam_role.nullplatform_mobile_store[0].arn : ""
}

output "role_name" {
  description = "Name of the mobile-store permissions role"
  value       = local.iam_create ? aws_iam_role.nullplatform_mobile_store[0].name : ""
}
