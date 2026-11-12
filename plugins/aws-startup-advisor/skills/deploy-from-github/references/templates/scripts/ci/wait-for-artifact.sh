#!/usr/bin/env bash
# Wait until the artifact for IMAGE_TAG is readable from this Region, then publish
# its location as step outputs for the deploy steps that follow.
#
#   container: the image must exist in the ECR repository of the *current account
#              and Region*. The build pushed it to the build account's primary
#              Region; ECR replication (configured by the bootstrap) copies it to
#              every other Region and to the production account. Replication is
#              asynchronous, so a deploy that starts seconds after a push waits here.
#   zip:       the object must exist in the artifact bucket (primary Region, build
#              account; production reads it cross-account). It is downloaded and
#              unpacked so both Terraform and aws-lambda-deploy can use it.
#
# Inputs (environment): DEPLOY_TARGET, APP_NAME, IMAGE_TAG, REGION, WAIT_SECONDS,
#                       ECR_REPOSITORY (container), ARTIFACT_BUCKET (zip)
# Outputs ($GITHUB_OUTPUT): image_uri | artifact_path, artifact_dir
#
# WAIT_SECONDS=0 turns this into a plain existence check (used by the tag run to
# refuse a tag whose commit never went through staging).
set -euo pipefail

: "${IMAGE_TAG:?IMAGE_TAG is required}"
: "${REGION:?REGION is required}"
: "${APP_NAME:?APP_NAME is required}"
WAIT_SECONDS="${WAIT_SECONDS:-600}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"

# Same rule as build.sh: lambda is always a zip, a Dockerfile means container.
artifact_kind() {
  if [[ "${DEPLOY_TARGET:-}" == "lambda" ]]; then echo zip
  elif [[ -f Dockerfile ]]; then echo container
  else echo zip
  fi
}

deadline=$(( $(date +%s) + WAIT_SECONDS ))
attempt=0
until_found() {
  # $1: a command that exits 0 when the artifact is present
  while ! "$@"; do
    if (( $(date +%s) >= deadline )); then
      echo "::error::artifact for ${IMAGE_TAG} not found in ${REGION} after ${WAIT_SECONDS}s. A production tag must point at a commit that already reached staging (that build publishes the artifact)." >&2
      exit 1
    fi
    attempt=$((attempt + 1))
    echo "waiting for artifact (attempt ${attempt})..."
    sleep 15
  done
}

case "$(artifact_kind)" in
  container)
    : "${ECR_REPOSITORY:?ECR_REPOSITORY is required for a container deploy}"
    account_id="$(aws sts get-caller-identity --query Account --output text)"
    image_uri="${account_id}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPOSITORY}:${IMAGE_TAG}"
    until_found aws ecr describe-images --region "$REGION" \
      --repository-name "$ECR_REPOSITORY" --image-ids "imageTag=${IMAGE_TAG}" \
      --query 'imageDetails[0].imageDigest' --output text
    echo "image present: ${image_uri}"
    echo "image_uri=${image_uri}" >> "$OUT"
    ;;
  zip)
    : "${ARTIFACT_BUCKET:?ARTIFACT_BUCKET is required for a zip deploy}"
    key="${APP_NAME}/${IMAGE_TAG}/function.zip"
    until_found aws s3api head-object --bucket "$ARTIFACT_BUCKET" --key "$key"
    if (( WAIT_SECONDS == 0 )); then
      echo "artifact present: s3://${ARTIFACT_BUCKET}/${key}"
      exit 0
    fi
    dir="${RUNNER_TEMP:-/tmp}/artifact"
    rm -rf "$dir" && mkdir -p "$dir/unpacked"
    aws s3 cp "s3://${ARTIFACT_BUCKET}/${key}" "$dir/function.zip" --only-show-errors
    unzip -q "$dir/function.zip" -d "$dir/unpacked"
    echo "artifact present: s3://${ARTIFACT_BUCKET}/${key}"
    echo "artifact_path=${dir}/function.zip" >> "$OUT"
    echo "artifact_dir=${dir}/unpacked" >> "$OUT"
    ;;
esac
