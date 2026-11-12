# Staging account: the build account. Lists the production account so it can read
# the artifacts this account publishes.
app_name          = "example"
stage             = "staging"
github_repository = "acme/example"
# github_repository_ids = "123456/789012"   # repositories created on or after 2026-07-15
primary_region                = "us-west-2"
regions                       = ["us-west-2", "us-east-1"]
deploy_target                 = "terraform"
artifact_kind                 = "zip"
is_build_account              = true
artifact_consumer_account_ids = ["222222222222"]
create_oidc_provider          = true
create_plan_role              = true
