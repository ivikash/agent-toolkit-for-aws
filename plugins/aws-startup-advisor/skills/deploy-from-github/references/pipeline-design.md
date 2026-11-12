# Pipeline design: the decisions and why

This file explains the shape the templates implement. Read it with the user in DESIGN. Every
section ends with what to say when they want something else.

## Contents

- [The shape](#the-shape)
- [Stages: two, not three](#stages-two-not-three)
- [The approval gate](#the-approval-gate)
- [One artifact, promoted](#one-artifact-promoted)
- [Regions](#regions)
- [The bake](#the-bake)
- [Rollback](#rollback)
- [Deploy targets](#deploy-targets)
- [The Terraform contract](#the-terraform-contract)
- [Naming conventions](#naming-conventions)
- [Repository variables](#repository-variables)

## The shape

```
pull request ──▶ ci.yml ──▶ lint, test, build (no publish) ──▶ terraform plan (staging, read-only)

push to main ──▶ deploy.yml ──▶ build once ──▶ staging: every Region in parallel ──▶ bake each

push tag v* ──▶ deploy.yml ──▶ artifact exists? ──▶ production: Region 1 ──▶ bake ──▶ Region 2 ──▶ bake ...
```

Three workflow files, four scripts, one bootstrap. Nothing is generated per Region or per stage
except the bootstrap's provider list. A new Region is a repository variable change plus one
provider block.

## Stages: two, not three

`staging` receives every commit on `main`. `production` receives tagged commits. There is no `dev`
stage: a developer's laptop is the dev environment, and a two-person team does not need a third
copy of its infrastructure to pay for and keep in sync.

Ephemeral per-pull-request environments are a real feature with real cost (a full copy of the
infrastructure per open PR). This skill does not generate them. Say so when asked, and name what
they would need: a `pull_request` trigger on `deploy-stage.yml`, a stage name derived from the PR
number, and a teardown job on `closed`.

*When they want a `dev` stage anyway:* it is a third bootstrap apply and a third role. The
workflows need a `dev` job that triggers on a branch of their choosing. Add it, but say what it
adds to the monthly bill first.

## The approval gate

Production needs a human decision between "tests passed" and "customers see it". What that
decision looks like depends on the GitHub plan, because required reviewers on environments are a
paid feature on private repositories.

| Repository | Required reviewers available? | The gate |
|---|---|---|
| Public, any plan | Yes | `production` environment with required reviewers and a deployment tag rule `v*`. A person approves the waiting job in the Actions UI. |
| Private, GitHub Enterprise | Yes | Same as public. |
| Private, GitHub Team or Pro | No (deployment branch and tag rules yes) | The tag rule `v*` on the environment blocks deploys from branches. The human decision is creating the tag. |
| Private, GitHub Free | No (environments cannot be configured at all) | The human decision is creating the tag. GitHub enforces nothing. |

In the last two rows GitHub is not the gate, **IAM is**. The production role's trust policy accepts
only the subject `repo:<owner>/<name>:environment:production:ref:refs/tags/v*`. A job on a branch
that adds `environment: production` to itself gets a token whose `ref` is `refs/heads/...`, and
`AssumeRoleWithWebIdentity` is denied. Nobody deploys to production without a `v*` tag, on any plan,
and a tag is something a person pushes.

That is why the OIDC subject is customized to include both the environment and the ref
(`<repo>/scripts/ci/set-github-variables.sh` sets the template `["repo","environment","ref"]`). GitHub's
default subject carries one or the other: with an environment on the job it is
`repo:<owner>/<name>:environment:production`, which says nothing about the ref.

Two more lines of defence the user controls, both free on every plan for public repositories and
on Team and above for private ones: a branch protection or ruleset on `main` (reviews before
merge), and a tag protection rule on `v*` (who may create tags). Recommend both and say which plan
has them.

*When they want a click-to-approve gate on a private Free or Team repository:* it costs a plan
upgrade. The tag-driven gate is not a workaround for a missing feature, it is a smaller gate that
costs nothing. Write the tag convention in `DEPLOYMENT.md` (`git tag v1.4.0 && git push origin v1.4.0`,
or `gh release create v1.4.0 --generate-notes`).

## One artifact, promoted

The `build` job runs on the push to `main`, once, with the staging role. It publishes the artifact
under the commit SHA: a container image pushed to the ECR repository in **every Region** (the same
local image, so the bytes are identical and there is no replication to wait for), or a zip uploaded
to the artifact bucket in the primary Region.

The tag run does not build. Its first job, `check-artifact`, signs in as production and asks
whether the artifact for `github.sha` exists. If the commit never went through staging there is no
artifact, and the run fails with a message that says so. Production therefore deploys the same bytes
that staging ran, and a tag on an untested commit cannot reach production by accident.

Cross-account: the bootstrap in the build account writes a repository policy on each ECR repository
and a bucket policy on the artifact bucket that let the production account read. The production
role's own policy allows the matching reads. Both halves are needed, and both are generated.

ECR tags are **immutable** in the bootstrap's repositories. A rebuild of the same SHA cannot
overwrite what staging tested. `build.sh` checks before pushing and skips a tag that exists.

*When they want to rebuild on the tag instead:* it is simpler to read and weaker to run. The bits in
production were never in staging. Say that, and only then change `deploy.yml` to add the `build` job
to the tag path.

## Regions

One Region is the default. `architect-for-startups` lists multi-region before product-market fit as
an anti-pattern, and this skill does not argue with it. When the user has a reason (a latency
target, a residency rule, a recovery objective) the pipeline handles any number of Regions with the
same three files:

- `REGIONS` is a JSON array in a repository variable, primary Region first.
- **Staging** deploys all Regions in parallel (`fail-fast: false`): a problem in one Region is a
  finding, not a reason to stop looking at the others.
- **Production** deploys one Region at a time (`max-parallel: 1`, `fail-fast: true`), in the order
  listed. Each Region bakes before the next starts. A failed bake stops the rollout with the earlier
  Regions on the new version and the later ones on the old. That is the intended state: a partial
  rollout that a person inspects, not a fleet-wide regression.
- Each (stage, Region) pair has its own Terraform state key and its own concurrency group.
- Container images are pushed to each Region's own ECR repository, so a Region never depends on
  another Region to start a task.

*When they want all production Regions in parallel:* set `max-parallel` to the Region count. Say
what they lose: the first Region as a canary.

## The bake

`verify-deploy.sh` runs after every deploy:

1. **Health.** GET the stage's URL until it returns 200, for up to five minutes. The URL is the
   Terraform root's `health_url` output when it has one, otherwise `HEALTH_URL_TEMPLATE` with
   `{stage}` and `{region}` replaced. Neither means no health check, and the log says so with a
   warning.
2. **Alarms.** Watch every CloudWatch alarm named `<app>-<stage>-<region>-*` for the bake window
   (60 seconds in staging, 300 in production). Any alarm in `ALARM` fails the job. **No alarms with
   that prefix passes with a visible warning**: the deploy worked, but nothing was watching it. The
   fix is to create alarms with that prefix, which is what `observe-on-aws` does. On an Omni-enabled
   account, note that Omni alerts are not CloudWatch alarms and the bake does not read them. The bake needs at least one CloudWatch
   alarm per stage and Region.

The bake is what makes the sequential production rollout mean something. Without alarms it is a
sleep.

For the `terraform` target with ECS, also turn on the ECS deployment circuit breaker with rollback
in the application's Terraform. Then a service that never becomes healthy rolls itself back and
`terraform apply` fails, before the bake even starts. `tf-best-practices` covers the resource.

## Rollback

Rollback is a re-run of a previous version, not a special path:

```sh
gh workflow run deploy.yml --ref v1.3.2 -f stage=production
```

`workflow_dispatch` runs the workflow at the chosen ref. The tag's artifact still exists (ECR keeps
the newest 50 tagged images, the artifact bucket keeps 90 days), the production role trusts the tag
ref, and the sequential rollout and bake apply as they do to a forward deploy. Staging rolls back
the same way with `--ref <commit-on-main> -f stage=staging`.

What rollback does not undo: database migrations and other one-way changes. Say so in
`DEPLOYMENT.md`.

## Deploy targets

| Target | Who owns the infrastructure | What the deploy job does | Role permissions |
|---|---|---|---|
| `terraform` | Terraform, in the application repository | `terraform init` with the stage and Region state key, `plan`, `apply` the shown plan. The artifact reference arrives as `TF_VAR_image_uri` or `TF_VAR_artifact_path`. | PowerUserAccess plus IAM scoped to `<app>-*` names. The broadest role in this skill. |
| `ecs` | Something else (console, CDK, an earlier Terraform) | Render `deploy/ecs/<stage>.json` with the new image, register it, update the service `<app>-<stage>` in cluster `<app>-<stage>`, wait for stability. | Register task definitions, update that one service, pass `<app>-*` roles to ECS tasks. |
| `lambda` | Something else | Download the zip, `aws-lambda-deploy` into function `<app>-<stage>`, publish a version. | Update that one function. |

`ecs` and `lambda` are code-only. They never create infrastructure, which is why their roles are
small. `terraform` creates infrastructure, which is why its role is not.

## The Terraform contract

For the `terraform` target the application's root (default `infra/`) must accept:

```hcl
variable "region" { type = string }        # the Region this apply targets
variable "image_uri" {                      # container deploys
  type    = string
  default = ""
}
variable "artifact_path" {                  # zip deploys: a local path to function.zip
  type    = string
  default = ""
}
variable "image_tag" {                      # the commit SHA, for labels and service.version
  type    = string
  default = ""
}
```

and a `backend "s3" {}` block with no arguments (the workflow supplies them with
`-backend-config`), plus `env/staging.tfvars` and `env/production.tfvars`. The workflow passes the
Region and artifact as `TF_VAR_*` environment variables, so a root that only uses one of
`image_uri` or `artifact_path` declares both and ignores one. Terraform ignores a `TF_VAR_` for an
undeclared variable, so declaring them is for clarity, not correctness.

One optional output: `health_url`. When the root declares it, `deploy-stage.yml` reads it after
apply and the bake uses it instead of `HEALTH_URL_TEMPLATE`. Roots whose endpoint is not
predictable from a template (a Lambda function URL, an auto-named load balancer) declare it.

[`templates/infra-lambda/`](templates/infra-lambda/) is a complete root that satisfies the
contract.

## Naming conventions

The templates rely on names rather than on more variables:

| Thing | Name |
|---|---|
| Deploy role | `<app>-<stage>-github-deploy` |
| Plan role | `<app>-staging-github-plan` |
| State bucket | `<app>-<stage>-tfstate-<accountId>` |
| State key | `<app>/<stage>/<region>/terraform.tfstate` |
| ECR repository | `<app>` (same name in every Region) |
| Artifact bucket | `<app>-artifacts-<accountId>` |
| Artifact key | `<app>/<sha>/function.zip` |
| ECS cluster and service, Lambda function | `<app>-<stage>` |
| ECS container | `app` |
| Task definition file | `deploy/ecs/<stage>.json` |
| Alarms the bake watches | `<app>-<stage>-<region>-*` |
| GitHub environments | `plan`, `staging`, `production` |

## Repository variables

Set by `<repo>/scripts/ci/set-github-variables.sh`. None is a secret.

| Variable | Value |
|---|---|
| `APP_NAME` | The app name used in every resource name |
| `DEPLOY_TARGET` | `terraform`, `ecs` or `lambda` |
| `REGIONS` | JSON array, primary first, e.g. `["us-west-2","us-east-1"]` |
| `PRIMARY_REGION` | First entry of `REGIONS` |
| `TF_DIR` | Path of the Terraform root, default `infra` |
| `AWS_ROLE_ARN_PLAN` | Plan role in the staging account |
| `AWS_ROLE_ARN_STAGING`, `AWS_ROLE_ARN_PRODUCTION` | Deploy role per stage |
| `TF_STATE_BUCKET_STAGING`, `TF_STATE_BUCKET_PRODUCTION` | State bucket per stage |
| `ECR_REPOSITORY` | ECR repository name (container artifacts) |
| `ARTIFACT_BUCKET` | Artifact bucket (zip artifacts) |
| `HEALTH_URL_TEMPLATE` | Optional, with `{stage}` and `{region}` placeholders |
| `LAMBDA_HANDLER`, `LAMBDA_RUNTIME` | `lambda` target only |
