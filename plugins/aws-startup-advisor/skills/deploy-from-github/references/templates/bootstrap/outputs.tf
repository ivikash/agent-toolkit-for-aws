# scripts/ci/set-github-variables.sh reads these from `terraform output -json`.

output "account_id" {
  value = local.account_id
}

output "stage" {
  value = var.stage
}

output "primary_region" {
  value = var.primary_region
}

output "regions" {
  value = var.regions
}

output "deploy_role_arn" {
  description = "Role the pipeline assumes for this stage."
  value       = aws_iam_role.deploy.arn
}

output "deploy_role_trusts" {
  description = "The one OIDC subject the deploy role accepts."
  value       = local.deploy_subject
}

output "plan_role_arn" {
  description = "Read-only role pull requests assume for terraform plan. Empty when not created."
  value       = var.create_plan_role ? aws_iam_role.plan[0].arn : ""
}

output "state_bucket" {
  description = "Terraform state bucket for the application in this stage."
  value       = aws_s3_bucket.state.bucket
}

output "ecr_repository_name" {
  description = "ECR repository name, identical in every Region. Empty unless this is the build account and the artifact is a container."
  value       = local.create_ecr ? module.ecr_primary[0].repository_name : ""
}

output "ecr_repository_urls" {
  description = "ECR repository URL per Region."
  value = local.create_ecr ? merge(
    { (var.primary_region) = module.ecr_primary[0].repository_url },
    length(module.ecr_us_east_1) > 0 ? { "us-east-1" = module.ecr_us_east_1[0].repository_url } : {},
  ) : {}
}

output "artifact_bucket" {
  description = "Bucket for zip artifacts. Empty unless this is the build account and the artifact is a zip."
  value       = local.create_bucket ? aws_s3_bucket.artifacts[0].bucket : ""
}
