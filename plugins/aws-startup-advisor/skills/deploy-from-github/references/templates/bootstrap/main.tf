# Identity, trust, and state for one stage.
#
#   OIDC provider  - lets GitHub Actions in this repository sign in to this account
#                    with a short-lived token. No access keys anywhere.
#   deploy role    - what the pipeline becomes for this stage. Trusts exactly one
#                    OIDC subject: this repository, this stage's environment, and
#                    this stage's ref (the staging branch, or production tags).
#   plan role      - read-only, trusted by pull requests only (staging, terraform).
#   state bucket   - Terraform state for the application, native S3 locking.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  name       = "${var.app_name}-${var.stage}"

  # repo:<owner>/<name> or, for immutable subjects, repo:<owner>@<id>/<name>@<id>
  repo_claim = var.github_repository_ids == "" ? var.github_repository : format(
    "%s@%s/%s@%s",
    split("/", var.github_repository)[0], split("/", var.github_repository_ids)[0],
    split("/", var.github_repository)[1], split("/", var.github_repository_ids)[1],
  )

  # Subjects follow the repository's customized template repo:environment:ref
  # (scripts/ci/set-github-variables.sh sets it).
  stage_ref      = var.stage == "production" ? "refs/tags/${var.production_tag_pattern}" : "refs/heads/${var.staging_branch}"
  deploy_subject = "repo:${local.repo_claim}:environment:${var.stage}:ref:${local.stage_ref}"
  plan_subject   = "repo:${local.repo_claim}:environment:plan:ref:refs/pull/*/merge"

  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn

  tags = {
    app        = var.app_name
    stage      = var.stage
    managed-by = "deploy-from-github-bootstrap"
  }
}

# ---- OIDC provider ------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # No thumbprint: IAM validates GitHub's issuer against its own trusted CA list.
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

# ---- Terraform state bucket -----------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = "${local.name}-tfstate-${local.account_id}"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ---- Deploy role -----------------------------------------------------------------

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.deploy_subject]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${local.name}-github-deploy"
  description          = "GitHub Actions deploy role for ${var.app_name} ${var.stage}. Trusts ${local.deploy_subject}."
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  max_session_duration = 3600
}

# Shared by every deploy target: state, alarms for the bake, artifact reads.
data "aws_iam_policy_document" "deploy_common" {
  statement {
    sid       = "StateBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning"]
    resources = [aws_s3_bucket.state.arn]
  }
  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/${var.app_name}/${var.stage}/*"]
  }
  statement {
    sid       = "BakeReadsAlarms"
    actions   = ["cloudwatch:DescribeAlarms"]
    resources = ["*"]
  }
  statement {
    sid       = "ArtifactBucketRead"
    actions   = ["s3:GetObject"]
    resources = ["arn:${local.partition}:s3:::${var.app_name}-artifacts-*/${var.app_name}/*"]
  }
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = ["arn:${local.partition}:ecr:*:*:repository/${var.app_name}"]
  }
}

resource "aws_iam_role_policy" "deploy_common" {
  name   = "common"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy_common.json
}

# Build account only: push images, upload zips.
data "aws_iam_policy_document" "deploy_build" {
  count = var.is_build_account ? 1 : 0

  statement {
    sid = "EcrPush"
    actions = [
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = ["arn:${local.partition}:ecr:*:${local.account_id}:repository/${var.app_name}"]
  }
  statement {
    sid       = "ArtifactBucketWrite"
    actions   = ["s3:PutObject", "s3:ListBucket"]
    resources = ["arn:${local.partition}:s3:::${var.app_name}-artifacts-${local.account_id}", "arn:${local.partition}:s3:::${var.app_name}-artifacts-${local.account_id}/${var.app_name}/*"]
  }
}

resource "aws_iam_role_policy" "deploy_build" {
  count  = var.is_build_account ? 1 : 0
  name   = "build"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy_build[0].json
}

# terraform target: PowerUserAccess (everything except IAM and account settings)
# plus IAM limited to roles and policies that carry the app's name. This is the
# broadest role in the bootstrap, because `terraform apply` creates whatever the
# application needs. The upgrade when the team grows is a permissions boundary
# on every role Terraform creates. See references/oidc-and-iam.md.
resource "aws_iam_role_policy_attachment" "deploy_poweruser" {
  count      = var.deploy_target == "terraform" ? 1 : 0
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "deploy_terraform_iam" {
  count = var.deploy_target == "terraform" ? 1 : 0

  statement {
    sid = "ManageAppRoles"
    actions = [
      "iam:AttachRolePolicy", "iam:CreateRole", "iam:DeleteRole", "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy", "iam:GetRole", "iam:GetRolePolicy", "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole", "iam:ListRolePolicies", "iam:PassRole", "iam:PutRolePolicy",
      "iam:TagRole", "iam:UntagRole", "iam:UpdateAssumeRolePolicy", "iam:UpdateRole", "iam:UpdateRoleDescription",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${var.app_name}-*"]
  }
  statement {
    sid = "ManageAppPolicies"
    actions = [
      "iam:CreatePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:DeletePolicyVersion",
      "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions", "iam:TagPolicy", "iam:UntagPolicy",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:policy/${var.app_name}-*"]
  }
  statement {
    sid = "ManageAppInstanceProfiles"
    actions = [
      "iam:AddRoleToInstanceProfile", "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:TagInstanceProfile",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/${var.app_name}-*"]
  }
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole", "iam:GetRole", "iam:ListRoles"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/*"]
  }
}

resource "aws_iam_role_policy" "deploy_terraform_iam" {
  count  = var.deploy_target == "terraform" ? 1 : 0
  name   = "terraform-iam"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy_terraform_iam[0].json
}

# ecs target: register a task definition and roll the service. Nothing else.
data "aws_iam_policy_document" "deploy_ecs" {
  count = var.deploy_target == "ecs" ? 1 : 0

  statement {
    sid       = "TaskDefinitions"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition", "ecs:DeregisterTaskDefinition"]
    resources = ["*"]
  }
  statement {
    sid     = "RollService"
    actions = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = [
      "arn:${local.partition}:ecs:*:${local.account_id}:service/${local.name}/${local.name}",
    ]
  }
  statement {
    sid       = "PassTaskRoles"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${var.app_name}-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "deploy_ecs" {
  count  = var.deploy_target == "ecs" ? 1 : 0
  name   = "ecs-deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy_ecs[0].json
}

# lambda target: update the code of one function and publish a version.
data "aws_iam_policy_document" "deploy_lambda" {
  count = var.deploy_target == "lambda" ? 1 : 0

  statement {
    sid = "UpdateFunction"
    actions = [
      "lambda:GetFunction", "lambda:GetFunctionConfiguration", "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration", "lambda:PublishVersion", "lambda:ListVersionsByFunction",
    ]
    resources = ["arn:${local.partition}:lambda:*:${local.account_id}:function:${local.name}"]
  }
}

resource "aws_iam_role_policy" "deploy_lambda" {
  count  = var.deploy_target == "lambda" ? 1 : 0
  name   = "lambda-deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy_lambda[0].json
}

# ---- Plan role (pull requests, read-only) ---------------------------------------------

data "aws_iam_policy_document" "plan_trust" {
  count = var.create_plan_role ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.plan_subject]
    }
  }
}

resource "aws_iam_role" "plan" {
  count                = var.create_plan_role ? 1 : 0
  name                 = "${local.name}-github-plan"
  description          = "Read-only role for terraform plan on pull requests. Trusts ${local.plan_subject}."
  assume_role_policy   = data.aws_iam_policy_document.plan_trust[0].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  count      = var.create_plan_role ? 1 : 0
  role       = aws_iam_role.plan[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}
