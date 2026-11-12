# Verifying: before the first push, and the first run

## Contents

- [Local checks](#local-checks)
- [Reading the subject GitHub actually sent](#reading-the-subject-github-actually-sent)
- [The first run, step by step](#the-first-run-step-by-step)
- [Troubleshooting](#troubleshooting)

## Local checks

Run all four before the first push. A tool that is not installed is reported with its install
command. Do not describe a check as passed when its tool did not run.

| Check | Command | Install |
|---|---|---|
| Workflow syntax, expressions, action inputs, embedded shell | `actionlint` (from the repository root, finds `.github/workflows` itself) | `brew install actionlint`, or `go install github.com/rhysd/actionlint/cmd/actionlint@latest`, or `mise use -g actionlint@latest` |
| Shell scripts | `shellcheck -S style scripts/ci/*.sh` | `brew install shellcheck`, `apt-get install shellcheck`, or `mise use -g shellcheck@latest` |
| Bootstrap formatting and validity | `terraform -chdir=infra/bootstrap fmt -check -recursive && terraform -chdir=infra/bootstrap init -backend=false && terraform -chdir=infra/bootstrap validate` | `mise use -g terraform@latest` or the HashiCorp installer |
| Application root (terraform target) | `terraform -chdir=infra init -backend=false && terraform -chdir=infra validate` | as above |

`actionlint` runs `shellcheck` on every `run:` block when `shellcheck` is on the path, which is why
both are listed. The templates pass all four with zero findings at `-S style`.

## Reading the subject GitHub actually sent

When a trust policy is denied, stop guessing the `sub` and read it. Add this step to any job once,
run it, and delete it:

```yaml
      - name: Print the OIDC subject (temporary)
        run: |
          token=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
            "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r .value)
          echo "$token" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq '{sub, aud, ref, environment, repository_id, repository_owner_id}'
```

The job needs `permissions: id-token: write` and an `environment:` when the subject template
includes the environment claim. Compare the printed `sub` to the role's trust policy character by
character. The printed `repository_id` and `repository_owner_id` are the ids for
`github_repository_ids`.

## The first run, step by step

1. **Bootstrap, staging account.** `terraform apply -var-file=env/staging.tfvars` in a `staging`
   workspace. Expect: one OIDC provider (or none, when it existed), two roles, one state bucket, and
   the ECR repositories or the artifact bucket. Save the outputs.
2. **Bootstrap, production account.** Same in a `production` workspace with
   `env/production.tfvars`. Expect: one provider, one role, one state bucket. No artifact store.
3. **Repository variables.** `<repo>/scripts/ci/set-github-variables.sh`. Expect: `gh variable list` shows
   every variable from `pipeline-design.md`, and
   `gh api repos/<owner>/<name>/actions/oidc/customization/sub` returns the three-claim template.
4. **Environments (public repository or Enterprise).** In the repository settings, create the
   `production` environment, add required reviewers, and set the deployment tag rule `v*`. Create
   `staging` with the branch rule `main`. On other plans GitHub creates the environments on first
   use and the IAM trust policy is the gate.
5. **Pull request.** Open one with the pipeline files. Expect `ci.yml`: the `checks` job passes, the
   `plan` job (terraform target) shows a plan per Region in the job summary with no changes applied.
   A denied sign-in here is a trust-policy or subject-template mistake, see Troubleshooting.
6. **Merge.** Expect `deploy.yml`: `build` publishes the artifact (the log names each Region's
   image or the S3 key), then one `Staging <region>` job per Region, each ending with the bake lines
   `health ok` (or the skip warning) and `bake passed` (or the no-alarms warning).
7. **Smoke test staging yourself.** The pipeline checked a health URL and the alarms. Look at the
   application once.
8. **Tag.** `git tag v0.1.0 && git push origin v0.1.0`. Expect `deploy.yml`: `check-artifact`
   passes (the artifact from step 6 exists), then `Production <region>` jobs one at a time, each
   baking for 300 seconds before the next.
9. **Rollback drill, once.** Tag `v0.1.1` with a trivial change, deploy it, then
   `gh workflow run deploy.yml --ref v0.1.0 -f stage=production`. Expect production back on
   `v0.1.0`. A team that has never rolled back does not know whether it can.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The token's `sub` does not match the trust policy. Four usual reasons, in order of frequency: the subject template was not set (`set-github-variables.sh` not run, or run on the wrong repository), the repository emits the immutable subject and the bootstrap has no `github_repository_ids`, the job has no `environment:`, or the ref is not the one the role trusts (a tag run from a branch, a dispatch on the wrong ref). | Print the subject (above). Set the template, set the ids, add the environment, or run on the right ref. |
| `Error: Credentials could not be loaded` with `Unable to get ACTIONS_ID_TOKEN_REQUEST_URL` | The job lacks `permissions: id-token: write`, or the workflow set `permissions: {}` and the job did not add its own. | Add the job-level permissions block. The templates have it. |
| GitHub refuses to mint a token with a message about the environment claim | The subject template includes `environment` and the job has none. | Add `environment:` to the job. |
| `EntityAlreadyExists` creating the OIDC provider | The account already trusts GitHub. | `create_oidc_provider = false`. |
| `check-artifact` fails: artifact not found | The tagged commit never reached staging, or the tag run started before the staging build finished. | Tag a commit that is on `main` and whose staging run completed. Re-run the tag workflow. |
| `wait-for-artifact.sh` times out in a Region | The build pushed to every Region in `REGIONS` at build time. A Region added later has no images for old commits. | Push a new commit to `main` so the build publishes to the new Region, then tag it. |
| `AccessDenied` pulling the image in production | The repository policy in the build account does not list the production account. | Add the production account id to `artifact_consumer_account_ids` in the staging bootstrap and re-apply. |
| Health check never returns 200 | The URL template is wrong for this stage or Region, or the service is not up. | `curl` the rendered URL by hand. Fix the template, or look at the service. |
| `bake passed` with a warning about no alarms | No CloudWatch alarms named `<app>-<stage>-<region>-*`. | `observe-on-aws` creates them with that prefix. Omni alerts are not CloudWatch alarms and the bake does not read them. |
| An alarm fires during the production bake and the rollout stops | The new version is unhealthy in the first Region. This is the pipeline working. | Investigate with `operate-on-aws`. Roll back with `gh workflow run deploy.yml --ref <previous tag> -f stage=production`. |
| A job referencing an environment fails on a private GitHub Free repository | The plan cannot configure environments. The jobs still run on most repositories, but if GitHub refuses the environment reference, GitHub is the cause, not the templates. | Remove the `environment:` blocks and the `environment` claim from the subject template, and change the trust policies to `repo:<owner>/<name>:ref:<ref>`. The tag ref still gates production. |
| `terraform plan` on the PR fails with a lock error | A deploy holds the state lock. | The PR plan uses `-lock=false` and does not take the lock. A lock error here means a deploy is mid-apply and the state read raced it. Re-run after the deploy finishes. |
| Two deploys to the same stage and Region at once | Impossible by design: the concurrency group `deploy-<stage>-<region>` queues the second. | Nothing. Wait. |
