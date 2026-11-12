# One ECR repository in one Region, with a lifecycle policy and, when other
# accounts consume images, a repository policy that lets them pull.

terraform {
  required_version = ">= 1.11.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "repository_name" {
  description = "Repository name. The pipeline uses the app name."
  type        = string
}

variable "consumer_account_ids" {
  description = "Account ids allowed to pull from this repository."
  type        = list(string)
  default     = []
}

variable "image_retention_count" {
  description = "Tagged images to keep."
  type        = number
}

data "aws_partition" "current" {}

resource "aws_ecr_repository" "this" {
  name                 = var.repository_name
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after a day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the newest ${var.image_retention_count} tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.image_retention_count
        }
        action = { type = "expire" }
      },
    ]
  })
}

data "aws_iam_policy_document" "consumers" {
  count = length(var.consumer_account_ids) > 0 ? 1 : 0

  statement {
    sid = "ConsumerAccountsPull"
    principals {
      type        = "AWS"
      identifiers = [for id in var.consumer_account_ids : "arn:${data.aws_partition.current.partition}:iam::${id}:root"]
    }
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
    ]
  }
}

resource "aws_ecr_repository_policy" "consumers" {
  count      = length(var.consumer_account_ids) > 0 ? 1 : 0
  repository = aws_ecr_repository.this.name
  policy     = data.aws_iam_policy_document.consumers[0].json
}

output "repository_url" {
  value = aws_ecr_repository.this.repository_url
}

output "repository_name" {
  value = aws_ecr_repository.this.name
}
