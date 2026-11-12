# Artifact store. Build account only (is_build_account = true).
#
#   container: one ECR repository per Region, same name in each. The build job
#              pushes the same local image to every Region, so each Region's
#              service pulls from its own Region and a Region outage elsewhere
#              cannot stop it from starting tasks. Production pulls cross-account
#              from the same Region.
#   zip:       one artifact bucket in the primary Region, read cross-account.
#
# One module block per Region, each with its own provider alias. Keep this list
# in step with providers.tf and `regions`.

locals {
  create_ecr    = var.is_build_account && var.artifact_kind == "container"
  create_bucket = var.is_build_account && var.artifact_kind == "zip"
}

module "ecr_primary" {
  source = "./modules/ecr-regional"
  count  = local.create_ecr ? 1 : 0

  providers = { aws = aws }

  repository_name       = var.app_name
  consumer_account_ids  = var.artifact_consumer_account_ids
  image_retention_count = var.image_retention_count
}

module "ecr_us_east_1" {
  source = "./modules/ecr-regional"
  count  = local.create_ecr && contains(var.regions, "us-east-1") && var.primary_region != "us-east-1" ? 1 : 0

  providers = { aws = aws.us_east_1 }

  repository_name       = var.app_name
  consumer_account_ids  = var.artifact_consumer_account_ids
  image_retention_count = var.image_retention_count
}

# ---- zip artifacts -----------------------------------------------------------------

resource "aws_s3_bucket" "artifacts" {
  count  = local.create_bucket ? 1 : 0
  bucket = "${var.app_name}-artifacts-${local.account_id}"
}

resource "aws_s3_bucket_versioning" "artifacts" {
  count  = local.create_bucket ? 1 : 0
  bucket = aws_s3_bucket.artifacts[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  count  = local.create_bucket ? 1 : 0
  bucket = aws_s3_bucket.artifacts[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  count                   = local.create_bucket ? 1 : 0
  bucket                  = aws_s3_bucket.artifacts[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  count  = local.create_bucket ? 1 : 0
  bucket = aws_s3_bucket.artifacts[0].id
  rule {
    id     = "expire-old-artifacts"
    status = "Enabled"
    filter {}
    expiration {
      days = var.artifact_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "artifacts_consumers" {
  count = local.create_bucket && length(var.artifact_consumer_account_ids) > 0 ? 1 : 0

  statement {
    sid     = "ConsumerAccountsRead"
    actions = ["s3:GetObject"]
    principals {
      type        = "AWS"
      identifiers = [for id in var.artifact_consumer_account_ids : "arn:${local.partition}:iam::${id}:root"]
    }
    resources = ["${aws_s3_bucket.artifacts[0].arn}/${var.app_name}/*"]
  }
}

resource "aws_s3_bucket_policy" "artifacts_consumers" {
  count  = local.create_bucket && length(var.artifact_consumer_account_ids) > 0 ? 1 : 0
  bucket = aws_s3_bucket.artifacts[0].id
  policy = data.aws_iam_policy_document.artifacts_consumers[0].json
}
