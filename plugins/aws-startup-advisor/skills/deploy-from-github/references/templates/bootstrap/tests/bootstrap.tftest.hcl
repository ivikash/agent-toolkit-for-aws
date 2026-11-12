# Offline tests for the bootstrap's logic: which OIDC subject each role trusts,
# and which resources each account layout creates. Mock providers, no credentials.
#
#   terraform -chdir=infra/bootstrap test

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111111111111"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com"
    }
  }
}

mock_provider "aws" {
  alias = "us_east_1"
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
}

variables {
  app_name          = "example"
  github_repository = "acme/example"
  primary_region    = "us-west-2"
  regions           = ["us-west-2", "us-east-1"]
  deploy_target     = "terraform"
  artifact_kind     = "container"
}

run "staging_build_account" {
  command = plan

  variables {
    stage                         = "staging"
    is_build_account              = true
    artifact_consumer_account_ids = ["222222222222"]
  }

  assert {
    condition     = local.deploy_subject == "repo:acme/example:environment:staging:ref:refs/heads/main"
    error_message = "staging deploy role must trust the main branch through the staging environment"
  }
  assert {
    condition     = local.plan_subject == "repo:acme/example:environment:plan:ref:refs/pull/*/merge"
    error_message = "plan role must trust pull requests only"
  }
  assert {
    condition     = length(aws_iam_role.plan) == 1
    error_message = "staging with the terraform target creates the plan role"
  }
  assert {
    condition     = length(module.ecr_primary) == 1 && length(module.ecr_us_east_1) == 1
    error_message = "the build account creates one ECR repository per Region"
  }
  assert {
    condition     = length(aws_s3_bucket.artifacts) == 0
    error_message = "a container artifact needs no artifact bucket"
  }
  assert {
    condition     = length(aws_iam_role_policy.deploy_build) == 1
    error_message = "the build account's deploy role can publish artifacts"
  }
  assert {
    condition     = length(aws_iam_role_policy_attachment.deploy_poweruser) == 1 && length(aws_iam_role_policy.deploy_terraform_iam) == 1
    error_message = "the terraform target attaches PowerUserAccess and the scoped IAM policy"
  }
  assert {
    condition     = length(aws_iam_role_policy.deploy_ecs) == 0 && length(aws_iam_role_policy.deploy_lambda) == 0
    error_message = "the terraform target does not attach the ecs or lambda policies"
  }
  assert {
    condition     = aws_s3_bucket.state.bucket == "example-staging-tfstate-111111111111"
    error_message = "state bucket follows <app>-<stage>-tfstate-<account>"
  }
}

run "production_consumer_account" {
  command = plan

  variables {
    stage            = "production"
    is_build_account = false
    create_plan_role = false
  }

  assert {
    condition     = local.deploy_subject == "repo:acme/example:environment:production:ref:refs/tags/v*"
    error_message = "production deploy role must trust v* tags through the production environment"
  }
  assert {
    condition     = length(aws_iam_role.plan) == 0
    error_message = "production creates no plan role"
  }
  assert {
    condition     = length(module.ecr_primary) == 0 && length(module.ecr_us_east_1) == 0 && length(aws_s3_bucket.artifacts) == 0
    error_message = "a consumer account creates no artifact store"
  }
  assert {
    condition     = length(aws_iam_role_policy.deploy_build) == 0
    error_message = "a consumer account's deploy role cannot publish artifacts"
  }
}

run "immutable_subject" {
  command = plan

  variables {
    stage                 = "production"
    is_build_account      = false
    github_repository_ids = "123456/789012"
  }

  assert {
    condition     = local.deploy_subject == "repo:acme@123456/example@789012:environment:production:ref:refs/tags/v*"
    error_message = "repository ids switch the subject to the immutable form"
  }
}

run "zip_artifacts_lambda_target" {
  command = plan

  variables {
    stage                         = "staging"
    is_build_account              = true
    deploy_target                 = "lambda"
    artifact_kind                 = "zip"
    artifact_consumer_account_ids = ["222222222222"]
  }

  assert {
    condition     = length(aws_s3_bucket.artifacts) == 1 && length(aws_s3_bucket_policy.artifacts_consumers) == 1
    error_message = "a zip artifact creates the bucket and the consumer policy"
  }
  assert {
    condition     = length(module.ecr_primary) == 0
    error_message = "a zip artifact creates no ECR repository"
  }
  assert {
    condition     = length(aws_iam_role_policy.deploy_lambda) == 1 && length(aws_iam_role_policy_attachment.deploy_poweruser) == 0
    error_message = "the lambda target attaches only the lambda policy"
  }
}

run "existing_oidc_provider_is_reused" {
  command = plan

  variables {
    stage                = "staging"
    is_build_account     = true
    create_oidc_provider = false
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0 && length(data.aws_iam_openid_connect_provider.github) == 1
    error_message = "create_oidc_provider = false reads the existing provider instead of creating one"
  }
}
