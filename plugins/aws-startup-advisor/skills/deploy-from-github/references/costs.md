# Costs: what the pipeline itself costs

**Last updated:** 2026-11-12. Rates are list prices read from GitHub's pricing page and the AWS
pricing pages on that date, US East (N. Virginia) for AWS. Re-read the sources before quoting a
number that is more than a quarter old. The deploys themselves (the ECS service, the Lambda
function, the load balancer) are the application's own cost and are not estimated here.

## GitHub Actions

| Item | Rate |
|---|---|
| Public repository | Free. Standard GitHub-hosted runners cost nothing. |
| Private repository, included minutes per month | 2,000 on Free, 3,000 on Pro and Team, 50,000 on Enterprise Cloud |
| Private repository, past the allowance, Linux 2-core runner | $0.006 per minute |
| Self-hosted runner in a private repository (since 2026-03-01) | $0.002 per minute platform charge once the allowance is used |
| Storage for artifacts and caches past the plan's allowance | $0.25 per GB per month |

Minutes are billed per job, rounded up to the minute. A matrix job over three Regions is three
jobs.

**Estimate for this pipeline's shape** (one Region, container artifact, `terraform` target):

| Run | Jobs | Typical minutes |
|---|---|---|
| Pull request (`ci.yml`) | checks, plan | 4 to 8 |
| Push to main (`deploy.yml` staging) | build, staging deploy with a 60-second bake | 6 to 12 |
| Tag (`deploy.yml` production) | check-artifact, production deploy with a 300-second bake | 8 to 14 |

A team merging ten pull requests a week and tagging twice uses roughly 500 to 900 minutes a month.
That fits inside the Free allowance on a private repository. Each extra Region adds one deploy job
per run (about 3 to 8 minutes each). Say the number for their Region count.

## AWS, per account

| Item | Rate | For this pipeline |
|---|---|---|
| IAM roles, policies, OIDC provider | $0 | Always $0 |
| S3 state bucket | $0.023 per GB-month, requests fractions of a cent | Cents. State files are kilobytes. |
| S3 artifact bucket (zip artifacts) | $0.023 per GB-month | A 50 MB zip, 90-day retention, 40 deploys a month: about 6 GB, under $0.15 |
| ECR storage (container artifacts) | $0.10 per GB-month | 50 images of 200 MB kept, per Region: about $1 per Region per month. The lifecycle policy caps it. |
| ECR data transfer, same Region pull | $0 | Tasks pull from their own Region's repository |
| Cross-account pull, same Region | $0 | Production pulling from staging's repository in the same Region |
| CloudWatch `DescribeAlarms` during the bake | API requests, $0.01 per 1,000 after the free tier | Cents |

Total for the pipeline's own resources: **under $5 per month per account** for a single-Region
container app, with ECR storage the only line that grows.

## What is not in this estimate

- The application's compute, load balancer, database and logs. `architect-for-startups` estimates
  those.
- Terraform Cloud or HCP Terraform. The pipeline uses the S3 backend and needs neither.
- Third-party deploy tools. None are used.

## How to say it in DISCLOSE

One paragraph, with their numbers: *"The pipeline itself costs GitHub Actions minutes (free, your
repository is public) or (about N minutes a month against the 2,000 included on Free) and under $5
a month in AWS per account, almost all of it ECR storage capped by a lifecycle policy. IAM and OIDC
cost nothing. The things you deploy cost what they cost, and that is a separate conversation."*
