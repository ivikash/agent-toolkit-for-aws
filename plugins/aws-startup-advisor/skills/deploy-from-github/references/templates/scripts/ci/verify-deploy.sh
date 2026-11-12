#!/usr/bin/env bash
# Bake: prove the new version answers, then watch its alarms for a while.
#
# 1. Health: GET the stage's health URL until it returns 200, up to HEALTH_TIMEOUT
#    seconds. The URL is HEALTH_URL when set (a Terraform root's health_url output,
#    for URLs that cannot be predicted, such as Lambda function URLs), otherwise
#    HEALTH_URL_TEMPLATE with {stage} and {region} replaced, e.g.
#    https://api.{stage}.example.com/{region}/health. Neither set skips the health
#    check and says so.
# 2. Alarms: every BAKE_SECONDS, list CloudWatch alarms named <APP_NAME>-<stage>-<region>-*
#    in this Region. Any alarm in ALARM state fails the job, which stops a
#    multi-region production rollout before the next Region starts. No alarms
#    with that prefix is reported, not treated as success and not treated as
#    failure: the deploy still passes, with a visible warning.
#
# Inputs (environment): APP_NAME, STAGE, REGION, HEALTH_URL_TEMPLATE, BAKE_SECONDS,
#                       HEALTH_TIMEOUT (default 300)
# Output ($GITHUB_OUTPUT): url (the health URL, shown on the GitHub environment)
set -euo pipefail

: "${APP_NAME:?APP_NAME is required}"
: "${STAGE:?STAGE is required}"
: "${REGION:?REGION is required}"
BAKE_SECONDS="${BAKE_SECONDS:-60}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

url="${HEALTH_URL:-}"
if [[ -z "$url" && -n "${HEALTH_URL_TEMPLATE:-}" ]]; then
  url="${HEALTH_URL_TEMPLATE//\{stage\}/$STAGE}"
  url="${url//\{region\}/$REGION}"
fi
if [[ -n "$url" ]]; then
  echo "url=${url}" >> "$OUT"
  deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  until code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" || true)"; [[ "$code" == "200" ]]; do
    if (( $(date +%s) >= deadline )); then
      echo "::error::health check failed: ${url} returned ${code:-no response} for ${HEALTH_TIMEOUT}s" >&2
      exit 1
    fi
    echo "health ${url} -> ${code:-no response}, retrying..."
    sleep 10
  done
  echo "health ok: ${url}"
else
  echo "::warning::no health URL (HEALTH_URL and HEALTH_URL_TEMPLATE are empty), skipping the health check"
fi

prefix="${APP_NAME}-${STAGE}-${REGION}-"
names="$(aws cloudwatch describe-alarms --region "$REGION" --alarm-name-prefix "$prefix" \
  --query 'MetricAlarms[].AlarmName' --output text | tr '\t' '\n' | sed '/^$/d' || true)"
if [[ -z "$names" ]]; then
  echo "::warning::no CloudWatch alarms named ${prefix}* in ${REGION}; the bake has nothing to watch. Create alarms with that name prefix to make the bake meaningful."
  echo "- ${STAGE} ${REGION}: deployed, health ${url:-skipped}, no alarms to bake against" >> "$SUMMARY"
  exit 0
fi

count="$(echo "$names" | wc -l | tr -d ' ')"
echo "baking for ${BAKE_SECONDS}s against ${count} alarm(s):"
while IFS= read -r name; do echo "  ${name}"; done <<< "$names"
end=$(( $(date +%s) + BAKE_SECONDS ))
while :; do
  firing="$(aws cloudwatch describe-alarms --region "$REGION" --alarm-name-prefix "$prefix" \
    --state-value ALARM --query 'MetricAlarms[].AlarmName' --output text | tr '\t' '\n' | sed '/^$/d' || true)"
  if [[ -n "$firing" ]]; then
    echo "::error::alarm(s) in ALARM during bake: $(echo "$firing" | paste -sd, -)" >&2
    echo "- ${STAGE} ${REGION}: FAILED bake, alarms firing: $(echo "$firing" | paste -sd, -)" >> "$SUMMARY"
    exit 1
  fi
  (( $(date +%s) >= end )) && break
  sleep 30
done
echo "bake passed: ${count} alarm(s) stayed OK for ${BAKE_SECONDS}s"
echo "- ${STAGE} ${REGION}: deployed, health ${url:-skipped}, ${count} alarm(s) OK for ${BAKE_SECONDS}s" >> "$SUMMARY"
