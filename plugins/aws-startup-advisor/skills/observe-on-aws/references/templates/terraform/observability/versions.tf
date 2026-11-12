# The minimum set for one stage in one Region: three CloudWatch alarms on the
# symptoms customers feel, one composite alarm that pages, one dashboard, and the
# SNS topic the page goes to. Applied per (stage, Region), from the application's
# Terraform root or on its own.
#
# Alarm names follow <app>-<stage>-<region>-*, which is the prefix the
# deploy-from-github bake watches after every deploy.

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
