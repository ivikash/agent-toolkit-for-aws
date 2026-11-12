#!/usr/bin/env bash
# Write the repository variables the workflows read. Run once per repository after
# the bootstrap has been applied in every account; re-run whenever a value changes.
#
# Values are read from the bootstrap outputs (terraform output -json in each
# account's bootstrap directory) plus a few project choices. None of these is a
# secret: role ARNs, bucket names and Region lists are safe as plain variables,
# which is also what makes them work on every GitHub plan (environment secrets
# are not available in private repositories on GitHub Free).
#
# Usage:
#   scripts/ci/set-github-variables.sh <owner/repo> <staging-outputs.json> <production-outputs.json>
#
# Project choices are read from the environment with defaults:
#   APP_NAME (required), DEPLOY_TARGET=terraform|ecs|lambda (required),
#   REGIONS (JSON array, default from staging outputs), TF_DIR=infra,
#   HEALTH_URL_TEMPLATE (optional), LAMBDA_HANDLER / LAMBDA_RUNTIME (lambda target)
set -euo pipefail

repo="${1:?usage: $0 <owner/repo> <staging-outputs.json> <production-outputs.json>}"
staging="${2:?staging outputs json is required}"
production="${3:?production outputs json is required}"
: "${APP_NAME:?APP_NAME is required}"
: "${DEPLOY_TARGET:?DEPLOY_TARGET is required (terraform|ecs|lambda)}"
case "$DEPLOY_TARGET" in terraform|ecs|lambda) ;; *) echo "DEPLOY_TARGET must be terraform, ecs or lambda" >&2; exit 2 ;; esac
command -v gh >/dev/null || { echo "gh CLI is required" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

out() { jq -r --arg k "$2" '.[$k].value // empty' "$1"; }
out_json() { jq -c --arg k "$2" '.[$k].value // empty' "$1"; }

set_var() {
  local name="$1" value="$2"
  if [[ -z "$value" ]]; then echo "skip ${name} (empty)"; return; fi
  gh variable set "$name" --repo "$repo" --body "$value"
  echo "set ${name}=${value}"
}

set_var APP_NAME                  "$APP_NAME"
set_var DEPLOY_TARGET             "$DEPLOY_TARGET"
set_var REGIONS                   "${REGIONS:-$(out_json "$staging" regions)}"
set_var PRIMARY_REGION            "$(out "$staging" primary_region)"
set_var TF_DIR                    "${TF_DIR:-infra}"
set_var AWS_ROLE_ARN_PLAN         "$(out "$staging" plan_role_arn)"
set_var AWS_ROLE_ARN_STAGING      "$(out "$staging" deploy_role_arn)"
set_var AWS_ROLE_ARN_PRODUCTION   "$(out "$production" deploy_role_arn)"
set_var TF_STATE_BUCKET_STAGING   "$(out "$staging" state_bucket)"
set_var TF_STATE_BUCKET_PRODUCTION "$(out "$production" state_bucket)"
set_var ECR_REPOSITORY            "$(out "$staging" ecr_repository_name)"
set_var ARTIFACT_BUCKET           "$(out "$staging" artifact_bucket)"
set_var HEALTH_URL_TEMPLATE       "${HEALTH_URL_TEMPLATE:-}"
if [[ "$DEPLOY_TARGET" == "lambda" ]]; then
  set_var LAMBDA_HANDLER "${LAMBDA_HANDLER:?LAMBDA_HANDLER is required for the lambda target}"
  set_var LAMBDA_RUNTIME "${LAMBDA_RUNTIME:?LAMBDA_RUNTIME is required for the lambda target}"
fi

# The OIDC subject must carry the environment and the ref so the IAM trust policies
# can pin production to v* tags. Default subjects carry one or the other, not both.
gh api --method PUT "repos/${repo}/actions/oidc/customization/sub" \
  --input - <<'JSON'
{"use_default":false,"include_claim_keys":["repo","environment","ref"]}
JSON
echo "OIDC subject template set to repo:environment:ref"
echo "done. Verify with: gh variable list --repo ${repo}"
