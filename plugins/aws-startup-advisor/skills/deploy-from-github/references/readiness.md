# Readiness: what exists before anything is written

Every command here is read-only. Run them in this order and record each answer. DETECT routes on
the answers, and CLARIFY asks only about what is still unknown.

## 1. The repository

```sh
git rev-parse --show-toplevel                 # a git repository at all?
git remote get-url origin                     # github.com owner/name?
gh repo view --json nameWithOwner,isPrivate,visibility,createdAt,owner \
  --jq '{repo:.nameWithOwner, private:.isPrivate, created:.createdAt, owner:.owner.login}'
gh api repos/<owner>/<name> --jq '"\(.owner.id)/\(.id)"'      # ids for the immutable OIDC subject
gh api user --jq .plan.name                   # free | pro | team | enterprise (user-owned repos)
gh api orgs/<owner> --jq .plan.name           # for organization-owned repos
ls .github/workflows 2>/dev/null
grep -rl "aws-actions/configure-aws-credentials\|aws-access-key-id" .github/workflows 2>/dev/null
ls Dockerfile cdk.json template.yaml samconfig.toml 2>/dev/null
find . -maxdepth 3 -name '*.tf' -not -path './.terraform/*' | head
```

| Answer | Meaning |
|---|---|
| `createdAt` on or after `2026-07-15` | The repository emits the immutable OIDC subject. The bootstrap needs `github_repository_ids = "<ownerId>/<repoId>"`. Before that date the legacy name-only subject applies, unless the owner opted in or renamed the repository since. When in doubt, decode a token once (see `verifying.md`, "Reading the subject GitHub actually sent"). |
| `isPrivate: true` and plan `free`, `pro` or `team` | GitHub cannot require a reviewer on the production environment. The gate is the IAM trust policy on the tag ref. Say so in DESIGN. |
| `isPrivate: false`, or plan `enterprise` | Required reviewers and a `v*` tag rule on the `production` environment are available. Offer them in CLARIFY. |
| A workflow with `aws-access-key-id` | Long-lived keys in secrets. Offer the OIDC replacement. |
| A workflow with `configure-aws-credentials` and `role-to-assume` | OIDC already in use. Extend that workflow, never add a parallel one. |
| `cdk.json` or `template.yaml` | CDK or SAM owns the infrastructure. The `terraform` target does not apply. |
| `.tf` files | A Terraform root exists. Check it against the contract in `pipeline-design.md`. |
| `Dockerfile` | The artifact is a container image. Otherwise it is a zip. |

The `gh` plan lookups need the `read:org` scope for organizations. When `gh api orgs/<owner>` is
denied, ask the user which plan they are on rather than guessing. The gate decision depends on it.

## 2. The AWS sign-in

```sh
aws --version
aws sts get-caller-identity --output table    # account, role, or an error
aws configure get region
```

| Result | Meaning |
|---|---|
| Account and ARN print | Signed in. Note the account id, and whether the role is administrative (the bootstrap needs IAM permissions). |
| `ExpiredToken` or `The security token included in the request is invalid` | Expired, not absent. One refresh command away. Ask them to refresh, do not route to "no AWS". |
| `Unable to locate credentials` | Not signed in. Continue through DESIGN and GENERATE. The bootstrap apply waits. |
| `aws: command not found` | Install the CLI first. Give the one command for their platform. |

With two accounts (staging and production) the user signs in to each when applying that account's
bootstrap. Record both account ids: the staging bootstrap needs the production id in
`artifact_consumer_account_ids`.

## 3. What the account already has

```sh
aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text
aws iam list-roles --query "Roles[?contains(RoleName, 'github')].RoleName" --output text
aws s3api list-buckets --query "Buckets[?contains(Name, 'tfstate') || contains(Name, 'artifacts')].Name" --output text
aws ecr describe-repositories --query 'repositories[].repositoryName' --output text
```

| Result | Meaning |
|---|---|
| A provider ARN ending `oidc-provider/token.actions.githubusercontent.com` | The account already trusts GitHub. Set `create_oidc_provider = false` in the bootstrap. There can be only one per account, and a second create fails with `EntityAlreadyExists`. |
| Roles named `<app>-<stage>-github-deploy` or `<app>-staging-github-plan` | A previous run of this skill. Import them into the bootstrap state or reuse their ARNs directly. Do not create `-2` variants. |
| Other roles with `github` in the name | Someone built OIDC roles by hand. Read their trust policies (`aws iam get-role`) before deciding whether the bootstrap replaces or coexists with them. |
| A bucket named `<app>-<stage>-tfstate-<account>` | The state bucket exists. Import it. |
| An ECR repository named `<app>` | The build account already has the repository. Import it. |

A failed lookup is unknown, not empty. Never conclude that nothing exists from an `AccessDenied`.

## 4. Local tools for VERIFY

```sh
actionlint --version
shellcheck --version
terraform version
```

Missing tools are reported with the install command (`verifying.md` lists them). The skill does
not install tools on the user's machine without asking.
