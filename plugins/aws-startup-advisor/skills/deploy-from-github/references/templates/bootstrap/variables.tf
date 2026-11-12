variable "app_name" {
  description = "Short name for the application. Prefixes every resource this pipeline creates (roles, buckets, repositories, alarms)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.app_name))
    error_message = "app_name must be lowercase letters, digits and hyphens, 2 to 31 characters, starting with a letter."
  }
}

variable "stage" {
  description = "Stage this account serves: staging or production."
  type        = string

  validation {
    condition     = contains(["staging", "production"], var.stage)
    error_message = "stage must be staging or production."
  }
}

variable "github_repository" {
  description = "GitHub repository as owner/name, e.g. acme/api."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be owner/name."
  }
}

variable "github_repository_ids" {
  description = <<-EOT
    Owner id and repository id as "ownerId/repoId", for repositories that emit the
    immutable OIDC subject (created on or after 2026-07-15, or opted in). Leave empty
    for the legacy name-only subject. Find the ids with:
      gh api repos/<owner>/<name> --jq '"\(.owner.id)/\(.id)"'
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.github_repository_ids == "" || can(regex("^[0-9]+/[0-9]+$", var.github_repository_ids))
    error_message = "github_repository_ids must be empty or ownerId/repoId."
  }
}

variable "primary_region" {
  description = "Region that holds the state bucket and the artifact bucket. Must be the first entry of regions."
  type        = string
}

variable "regions" {
  description = "Every Region this stage deploys to, primary first. Must match the provider blocks in providers.tf."
  type        = list(string)

  validation {
    condition     = length(var.regions) >= 1 && var.regions[0] == var.primary_region
    error_message = "regions must have at least one entry and start with primary_region."
  }
}

variable "deploy_target" {
  description = "How the pipeline deploys: terraform (apply is the deploy), ecs (code-only into an existing service), or lambda (code-only into an existing function). Decides the deploy role's permissions."
  type        = string

  validation {
    condition     = contains(["terraform", "ecs", "lambda"], var.deploy_target)
    error_message = "deploy_target must be terraform, ecs or lambda."
  }
}

variable "artifact_kind" {
  description = "container (a Dockerfile in the repository) or zip. Decides whether ECR repositories or an artifact bucket are created in the build account."
  type        = string

  validation {
    condition     = contains(["container", "zip"], var.artifact_kind)
    error_message = "artifact_kind must be container or zip."
  }
}

variable "is_build_account" {
  description = "True in the account whose deploy role builds and publishes artifacts (staging). False in accounts that only consume them (production)."
  type        = bool
}

variable "artifact_consumer_account_ids" {
  description = "Build account only: AWS account ids allowed to pull images and download zips, i.e. the production account. Empty for a single-account layout."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.artifact_consumer_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "Every entry must be a 12-digit AWS account id."
  }
}

variable "staging_branch" {
  description = "Branch whose pushes deploy to staging."
  type        = string
  default     = "main"
}

variable "production_tag_pattern" {
  description = "Git tag pattern, as an IAM StringLike pattern, whose pushes deploy to production."
  type        = string
  default     = "v*"
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC identity provider. Set false when the account already has one (there can be only one per account)."
  type        = bool
  default     = true
}

variable "create_plan_role" {
  description = "Create the read-only role pull requests use for terraform plan. Needed in the staging account when deploy_target is terraform."
  type        = bool
  default     = true
}

variable "image_retention_count" {
  description = "How many tagged images each ECR repository keeps. Older ones are expired by lifecycle policy."
  type        = number
  default     = 50
}

variable "artifact_retention_days" {
  description = "Days a zip artifact stays in the artifact bucket before expiring."
  type        = number
  default     = 90
}
