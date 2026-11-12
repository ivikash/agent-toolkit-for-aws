# Production account: consumes artifacts, builds nothing, plans nothing on PRs.
app_name          = "example"
stage             = "production"
github_repository = "acme/example"
# github_repository_ids = "123456/789012"   # repositories created on or after 2026-07-15
primary_region                = "us-west-2"
regions                       = ["us-west-2", "us-east-1"]
deploy_target                 = "terraform"
artifact_kind                 = "zip"
is_build_account              = false
artifact_consumer_account_ids = []
create_oidc_provider          = true
create_plan_role              = false
