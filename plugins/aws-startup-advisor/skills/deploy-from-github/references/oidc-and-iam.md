# OIDC and IAM: who may deploy what

The bootstrap in [`templates/bootstrap/`](templates/bootstrap/) implements this file. Read it to
explain the roles in DISCLOSE, and to debug a denied `AssumeRoleWithWebIdentity`.

## Contents

- [How the sign-in works](#how-the-sign-in-works)
- [The subject, and why it is customized](#the-subject-and-why-it-is-customized)
- [Immutable subjects](#immutable-subjects)
- [The roles](#the-roles)
- [Order of operations](#order-of-operations)
- [Single-account layout](#single-account-layout)
- [Upgrades for later](#upgrades-for-later)

## How the sign-in works

1. The workflow job declares `permissions: id-token: write`.
2. `aws-actions/configure-aws-credentials` asks GitHub for an OIDC token. GitHub signs a JWT whose
   `sub` describes where the job runs and whose `aud` is `sts.amazonaws.com`.
3. The action calls `sts:AssumeRoleWithWebIdentity` with that token and the role ARN from the
   repository variable.
4. IAM checks the role's trust policy: the token's issuer must be the account's GitHub OIDC
   provider, `aud` must match, and `sub` must match the pattern. On success the job holds
   credentials for at most one hour (`max_session_duration = 3600`).

No access key exists at any point. There is nothing to rotate and nothing to leak.

The identity provider needs no certificate thumbprint: IAM validates GitHub's issuer against its
own trusted certificate authorities, and a thumbprint given anyway is ignored. The bootstrap creates
the provider without one. An account can hold exactly one provider for
`https://token.actions.githubusercontent.com`. When one exists, the bootstrap takes
`create_oidc_provider = false` and reads it.

## The subject, and why it is customized

GitHub's default `sub` is one of:

```
repo:<owner>/<name>:ref:refs/heads/main              # a job with no environment
repo:<owner>/<name>:environment:production           # a job with environment: production
repo:<owner>/<name>:pull_request                     # a pull_request job with no environment
```

Each form carries either the ref or the environment, never both. A trust policy on the second form
lets any job that writes `environment: production` into its YAML assume the production role, from
any branch. On a repository where GitHub cannot restrict who deploys to that environment (private
repositories on Free, Pro and Team), that is the whole gate gone.

So `<repo>/scripts/ci/set-github-variables.sh` sets the repository's subject template to:

```json
{"use_default": false, "include_claim_keys": ["repo", "environment", "ref"]}
```

Every job that signs in then presents:

```
repo:<owner>/<name>:environment:<env>:ref:<ref>
```

| Job | Environment | Subject |
|---|---|---|
| `ci.yml` plan | `plan` | `repo:acme/api:environment:plan:ref:refs/pull/42/merge` |
| `deploy.yml` build, staging | `staging` | `repo:acme/api:environment:staging:ref:refs/heads/main` |
| `deploy.yml` check-artifact, production | `production` | `repo:acme/api:environment:production:ref:refs/tags/v1.4.0` |

and the trust policies match exactly one pattern each:

| Role | `sub` pattern (StringLike) |
|---|---|
| `<app>-staging-github-plan` | `repo:acme/api:environment:plan:ref:refs/pull/*/merge` |
| `<app>-staging-github-deploy` | `repo:acme/api:environment:staging:ref:refs/heads/main` |
| `<app>-production-github-deploy` | `repo:acme/api:environment:production:ref:refs/tags/v*` |

Two consequences to tell the user:

- Once the `environment` claim is in the template, **every job that requests a token must have an
  `environment:`**, or GitHub refuses to mint the token. All jobs in the templates do.
- The template is repository-level. An organization template, when one exists, applies only to
  repositories that opted in. `set-github-variables.sh` sets the repository's own template, which
  wins.

`ForAllValues` has no place in these policies: it evaluates to true when the claim is absent.
`StringEquals` on `aud` and `StringLike` on `sub` are the whole condition.

## Immutable subjects

Repositories created on github.com on or after 2026-07-15, older repositories that opted in, and
older repositories renamed since that date emit the `repo` segment with permanent numeric ids:

```
repo:acme@123456/api@789012:environment:production:ref:refs/tags/v1.4.0
```

A trust policy written for `repo:acme/api:...` then fails with
`Not authorized to perform sts:AssumeRoleWithWebIdentity`. The bootstrap variable
`github_repository_ids = "123456/789012"` switches every subject to the immutable form. The ids come
from `gh api repos/acme/api --jq '"\(.owner.id)/\(.id)"'`. `verifying.md` shows how to read the
subject GitHub actually sent when in doubt.

The immutable form exists so that a deleted-and-recreated repository with the same name cannot mint
a token matching an old trust policy. Use it whenever the repository emits it.

## The roles

Per account. Names carry the app and the stage so two apps in one account never collide.

| Role | Trusts | Can do | Why |
|---|---|---|---|
| `<app>-<stage>-github-deploy` (all targets) | The stage's subject | Read and write the state bucket under `<app>/<stage>/`. `cloudwatch:DescribeAlarms` (the bake). Read `<app>-artifacts-*` objects and pull from any `<app>` ECR repository. | Every target deploys an artifact and bakes. |
| ... in the build account | | Push to `<app>` ECR repositories in this account. Write to `<app>-artifacts-<account>`. | The `build` job runs as staging. |
| ... `terraform` target | | `PowerUserAccess` (everything except IAM, Organizations, and account settings), plus create, update, delete and pass IAM roles, policies and instance profiles named `<app>-*`, plus create service-linked roles. | `terraform apply` creates whatever the application declares, including the task or function role. |
| ... `ecs` target | | Register task definitions. Describe and update the one service `<app>-<stage>`. Pass `<app>-*` roles to `ecs-tasks.amazonaws.com` only. | Code-only deploy into an existing service. |
| ... `lambda` target | | Get, update code and configuration, publish versions of the one function `<app>-<stage>`. | Code-only deploy into an existing function. |
| `<app>-staging-github-plan` | The `plan` subject on pull requests | `ReadOnlyAccess`. | `terraform plan -lock=false` on PRs reads state and the live account, writes nothing. |

The `terraform` deploy role is the broadest. Say that in DISCLOSE in these terms: *"In the staging
account the pipeline can create and change anything except IAM users and account settings, and it
can create IAM roles whose names start with `<app>-`. In production the same role exists with the
same reach. That is what letting Terraform deploy means. The upgrade when you have a platform
person is a permissions boundary on every role Terraform creates."*

Cross-account reads (production pulling the artifact staging built) need both halves: the identity
policy above on the production role, and a resource policy in the build account. The bootstrap
writes the resource policies when `artifact_consumer_account_ids` lists the production account.

## Order of operations

The bootstrap is Terraform with local state on first run, because the state bucket it creates does
not exist yet. A human with administrator access runs it, once per account:

```sh
cd infra/bootstrap
terraform init

# staging account
aws sts get-caller-identity                     # confirm: the staging account
terraform workspace new staging                 # local state in terraform.tfstate.d/staging/
terraform apply -var-file=env/staging.tfvars
terraform output -json > ../../.bootstrap-staging.json

# production account
aws sts get-caller-identity                     # confirm: now the production account
terraform workspace new production              # separate local state for the second account
terraform apply -var-file=env/production.tfvars
terraform output -json > ../../.bootstrap-production.json

# repository variables and the OIDC subject template, from the repository root
cd ../..
APP_NAME=<app> DEPLOY_TARGET=<terraform|ecs|lambda> \
  <repo>/scripts/ci/set-github-variables.sh <owner>/<name> .bootstrap-staging.json .bootstrap-production.json
```

One workspace per account keeps the two local states apart. Then move each workspace's state into
the bucket its apply created: uncomment the `backend "s3"` block in `versions.tf` with that
account's bucket and key, run `terraform init -migrate-state` in that workspace, and delete the
local `terraform.tfstate.d/` once both have migrated.

The `.bootstrap-*.json` files contain ARNs and bucket names, no secrets, and are gitignored by the
template `DEPLOYMENT.md` instructions.

## Single-account layout

Both stages in one account is accepted with its costs stated (`pipeline-design.md`). The bootstrap
applies twice in the same account, once per stage, with these differences:

- `create_oidc_provider = true` for the first apply, `false` for the second.
- `artifact_consumer_account_ids = []` in both: the production role reads the build artifacts under
  its own account's identity policy, no resource policy needed.
- `is_build_account = true` for staging, `false` for production, as in the two-account layout.

Everything else, including the name prefixes, is unchanged.

## Upgrades for later

Name these when the team asks "what would a platform engineer add", not before:

- **Permissions boundary.** A managed policy attached to every role Terraform creates, so a
  misconfigured application role can never exceed it. One `iam:PermissionsBoundary` condition on the
  deploy role's `iam:CreateRole` enforces it.
- **Pin `job_workflow_ref`.** Add it to the subject template so the role trusts only
  `deploy-stage.yml` at `refs/heads/main`, not any workflow in the repository.
- **A separate tooling account** for ECR and the artifact bucket, so staging and production both
  read from a third place and neither depends on the other.
- **Deployment protection rules** (required reviewers, wait timers) when the plan allows them.
