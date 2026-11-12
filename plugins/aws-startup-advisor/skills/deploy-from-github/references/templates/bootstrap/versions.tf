# Bootstrap: everything the pipeline needs before its first run.
# Applied once per AWS account (one per stage) by a human with administrator
# access. See references/oidc-and-iam.md for the order of operations.
#
# 1.11 is the first release where S3 native state locking (use_lockfile) is GA.

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # The bootstrap starts with local state, because the bucket it creates does
  # not exist yet. After the first apply, migrate the state into that bucket:
  # uncomment this block, fill in the bucket name from `terraform output`, and
  # run `terraform init -migrate-state`.
  #
  # backend "s3" {
  #   bucket       = "<state_bucket output>"
  #   key          = "<app_name>/<stage>/bootstrap/terraform.tfstate"
  #   region       = "<primary_region>"
  #   use_lockfile = true
  #   encrypt      = true
  # }
}
