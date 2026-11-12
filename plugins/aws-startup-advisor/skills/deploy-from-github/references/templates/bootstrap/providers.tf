# One provider per Region. Terraform cannot create providers from a variable, so
# the Regions are listed here, once, and `regions` in variables.tf must list the
# same ones in the same order (primary first). The skill writes this file from
# the Regions chosen in Clarify. To add a Region later: add a provider block, a
# module "ecr_<region>" block in artifacts.tf, and the entry in `regions`.

provider "aws" {
  region = var.primary_region
  default_tags {
    tags = local.tags
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = local.tags
  }
}
