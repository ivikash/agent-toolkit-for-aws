# Minimal application root for the `terraform` deploy target: one Lambda function
# deployed from the zip the pipeline built, a function URL for the health check,
# and a log group with a retention policy. Applied once per (stage, Region) by
# deploy-stage.yml, which supplies the backend and TF_VAR_region, TF_VAR_image_tag
# and TF_VAR_artifact_path.
#
# Resource names start with <app_name>- so the bootstrap's deploy role is allowed
# to create them.

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Arguments arrive from the workflow with -backend-config.
  backend "s3" {}
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      app        = var.app_name
      stage      = var.stage
      version    = var.image_tag
      managed-by = "terraform"
    }
  }
}

locals {
  name = "${var.app_name}-${var.stage}"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

resource "aws_cloudwatch_log_group" "function" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "function" {
  name               = "${local.name}-${var.region}-lambda"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "function" {
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.function.arn}:*"]
  }
}

resource "aws_iam_role_policy" "function" {
  name   = "runtime"
  role   = aws_iam_role.function.id
  policy = data.aws_iam_policy_document.function.json
}

resource "aws_lambda_function" "this" {
  function_name    = local.name
  role             = aws_iam_role.function.arn
  handler          = var.handler
  runtime          = var.runtime
  architectures    = [var.architecture]
  filename         = var.artifact_path
  source_code_hash = filebase64sha256(var.artifact_path)
  memory_size      = var.memory_mb
  timeout          = var.timeout_seconds
  publish          = true

  environment {
    variables = merge(
      {
        APP_NAME        = var.app_name
        STAGE           = var.stage
        SERVICE_VERSION = var.image_tag
      },
      var.environment,
    )
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.function.name
  }

  tracing_config {
    mode = var.tracing ? "Active" : "PassThrough"
  }

  depends_on = [aws_iam_role_policy.function]
}

resource "aws_lambda_function_url" "this" {
  function_name      = aws_lambda_function.this.function_name
  authorization_type = var.function_url_auth
}

resource "aws_lambda_permission" "url" {
  count                  = var.function_url_auth == "NONE" ? 1 : 0
  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.this.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}
