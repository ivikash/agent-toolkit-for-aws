"""Contracts for the deploy-from-github skill.

Static: the workflow templates pin every action to a commit SHA, hold no long-lived
credentials, grant permissions per job, give every OIDC job an environment, call the
reusable workflow with inputs it declares, and read only repository variables that
set-github-variables.sh writes. The naming conventions the scripts rely on agree with the
ones the references document.

Behavioural: verify-deploy.sh and wait-for-artifact.sh run against a stubbed `aws` and
`curl` and behave as documented: a firing alarm fails the bake, no alarms passes with a
warning, a missing artifact on a tag run fails with the staging message, a present zip is
downloaded and unpacked.
"""

from __future__ import annotations

import os
import re
import stat
import subprocess
import zipfile
from pathlib import Path

import pytest
import yaml

PLUGIN_ROOT = Path(__file__).resolve().parent.parent
SKILL = PLUGIN_ROOT / "skills" / "deploy-from-github"
TEMPLATES = SKILL / "references" / "templates"
WORKFLOWS = {p.name: p for p in (TEMPLATES / "workflows").glob("*.yml")}
SCRIPTS = TEMPLATES / "scripts" / "ci"
SHA_PIN = re.compile(r"^\s+uses:\s+([\w.-]+/[\w.-]+)@([0-9a-f]{40})\s+#\s+v\d+(\.\d+)*\s*$")
LOCAL_USES = re.compile(r"^\s+uses:\s+\./")


def _yaml(name: str) -> dict:
    return yaml.safe_load(WORKFLOWS[name].read_text(encoding="utf-8"))


# ---------------------------------------------------------------- frontmatter


def test_frontmatter_name_matches_directory_and_routes_away() -> None:
    text = (SKILL / "SKILL.md").read_text(encoding="utf-8")
    fm = yaml.safe_load(text.split("---", 2)[1])
    assert fm["name"] == "deploy-from-github"
    assert len(fm["description"]) <= 1024
    assert "Not for" in fm["description"]
    for sibling in ("aws-deployment", "architect-for-startups", "tf-best-practices", "operate-on-aws"):
        assert sibling in fm["description"], sibling


# ---------------------------------------------------------------- workflows


def test_three_workflow_templates_exist() -> None:
    assert set(WORKFLOWS) == {"ci.yml", "deploy.yml", "deploy-stage.yml"}


@pytest.mark.parametrize("name", sorted(WORKFLOWS))
def test_every_third_party_action_is_pinned_to_a_sha_with_its_tag(name: str) -> None:
    for line in WORKFLOWS[name].read_text(encoding="utf-8").splitlines():
        if re.match(r"^\s+uses:", line) and not LOCAL_USES.match(line):
            assert SHA_PIN.match(line), f"{name}: unpinned or uncommented action: {line.strip()}"


@pytest.mark.parametrize("name", sorted(WORKFLOWS))
def test_no_long_lived_credentials_and_no_default_permissions(name: str) -> None:
    text = WORKFLOWS[name].read_text(encoding="utf-8")
    assert "aws-access-key-id" not in text
    assert "aws-secret-access-key" not in text
    assert "secrets." not in text, "workflows read repository variables, never secrets"
    doc = _yaml(name)
    assert doc["permissions"] == {}, "top-level permissions must be empty"


@pytest.mark.parametrize("name", sorted(WORKFLOWS))
def test_every_job_that_signs_in_has_an_environment_and_id_token(name: str) -> None:
    doc = _yaml(name)
    for job_name, job in doc["jobs"].items():
        if "uses" in job:
            continue  # a reusable-workflow call: the called workflow owns the environment
        signs_in = any(
            "configure-aws-credentials" in str(step.get("uses", "")) for step in job.get("steps", [])
        )
        if signs_in:
            assert job.get("permissions", {}).get("id-token") == "write", f"{name}:{job_name}"
            assert "environment" in job, f"{name}:{job_name} signs in without an environment"


def test_deploy_calls_the_reusable_workflow_with_declared_inputs() -> None:
    deploy = _yaml("deploy.yml")
    stage = _yaml("deploy-stage.yml")
    declared = set(stage[True]["workflow_call"]["inputs"]) if True in stage else set(stage["on"]["workflow_call"]["inputs"])
    required = {k for k, v in (stage.get(True) or stage["on"])["workflow_call"]["inputs"].items() if v.get("required")}
    callers = {k: v for k, v in deploy["jobs"].items() if "uses" in v}
    assert set(callers) == {"staging", "production"}
    for job_name, job in callers.items():
        assert job["uses"] == "./.github/workflows/deploy-stage.yml"
        passed = set(job["with"])
        assert passed <= declared, f"{job_name} passes undeclared inputs {passed - declared}"
        assert required <= passed, f"{job_name} misses required inputs {required - passed}"


def test_production_rolls_one_region_at_a_time_and_staging_in_parallel() -> None:
    deploy = _yaml("deploy.yml")
    prod = deploy["jobs"]["production"]["strategy"]
    assert prod["max-parallel"] == 1 and prod["fail-fast"] is True
    staging = deploy["jobs"]["staging"]["strategy"]
    assert staging["fail-fast"] is False and "max-parallel" not in staging
    assert deploy["jobs"]["production"]["needs"] == "check-artifact"
    assert "build" not in deploy["jobs"]["production"].get("needs", []), "a tag run never builds"


def test_build_runs_only_on_the_way_to_staging() -> None:
    deploy = _yaml("deploy.yml")
    build_if = deploy["jobs"]["build"]["if"]
    assert "refs/heads/main" in build_if
    assert "refs/tags" not in build_if


def test_workflows_read_only_variables_that_the_setup_script_writes() -> None:
    written = set(re.findall(r"set_var\s+(\w+)", (SCRIPTS / "set-github-variables.sh").read_text(encoding="utf-8")))
    used = set()
    for path in WORKFLOWS.values():
        used |= set(re.findall(r"vars\.(\w+)", path.read_text(encoding="utf-8")))
    assert used <= written, f"workflows read variables the setup script never writes: {used - written}"


def test_setup_script_sets_the_three_claim_subject_template() -> None:
    text = (SCRIPTS / "set-github-variables.sh").read_text(encoding="utf-8")
    assert 'actions/oidc/customization/sub' in text
    assert '"include_claim_keys":["repo","environment","ref"]' in text


def test_scripts_are_executable_and_strict() -> None:
    for script in SCRIPTS.glob("*.sh"):
        mode = script.stat().st_mode
        assert mode & stat.S_IXUSR, f"{script.name} is not executable"
        head = script.read_text(encoding="utf-8").splitlines()
        assert head[0] == "#!/usr/bin/env bash"
        assert "set -euo pipefail" in head[:40], script.name


# ---------------------------------------------------------------- naming conventions


def test_alarm_prefix_convention_is_shared_by_script_and_references() -> None:
    script = (SCRIPTS / "verify-deploy.sh").read_text(encoding="utf-8")
    assert 'prefix="${APP_NAME}-${STAGE}-${REGION}-"' in script
    design = (SKILL / "references" / "pipeline-design.md").read_text(encoding="utf-8")
    assert "`<app>-<stage>-<region>-*`" in design
    stage_wf = WORKFLOWS["deploy-stage.yml"].read_text(encoding="utf-8")
    assert "<APP_NAME>-<stage>-<region>-*" in stage_wf


def test_bootstrap_subjects_match_the_reference_table() -> None:
    main_tf = (TEMPLATES / "bootstrap" / "main.tf").read_text(encoding="utf-8")
    assert 'deploy_subject = "repo:${local.repo_claim}:environment:${var.stage}:ref:${local.stage_ref}"' in main_tf
    assert 'plan_subject   = "repo:${local.repo_claim}:environment:plan:ref:refs/pull/*/merge"' in main_tf
    oidc = (SKILL / "references" / "oidc-and-iam.md").read_text(encoding="utf-8")
    assert "repo:acme/api:environment:production:ref:refs/tags/v*" in oidc
    assert "repo:acme/api:environment:plan:ref:refs/pull/*/merge" in oidc


def test_terraform_test_file_covers_both_stages_and_the_immutable_subject() -> None:
    tftest = (TEMPLATES / "bootstrap" / "tests" / "bootstrap.tftest.hcl").read_text(encoding="utf-8")
    for run in ("staging_build_account", "production_consumer_account", "immutable_subject", "zip_artifacts_lambda_target"):
        assert f'run "{run}"' in tftest


# ---------------------------------------------------------------- behavioural, stubbed aws


STUB_AWS = r'''#!/usr/bin/env bash
# Stub for the AWS CLI. Behaviour is driven by STUB_* variables.
set -euo pipefail
case "$1 $2" in
  "cloudwatch describe-alarms")
    if [[ " $* " == *" --state-value ALARM "* ]]; then printf '%s\n' "${STUB_FIRING:-}"
    else printf '%s\n' "${STUB_ALARMS:-}"; fi ;;
  "sts get-caller-identity") echo "111111111111" ;;
  "s3api head-object")
    [[ "${STUB_OBJECT_EXISTS:-0}" == "1" ]] || { echo "Not Found" >&2; exit 254; } ;;
  "s3 cp")
    cp "$STUB_ZIP" "$4" ;;
  "ecr describe-images")
    [[ "${STUB_IMAGE_EXISTS:-0}" == "1" ]] || { echo "ImageNotFoundException" >&2; exit 254; }
    echo "sha256:abc" ;;
  *) echo "stub aws: unhandled: $*" >&2; exit 99 ;;
esac
'''

STUB_CURL = r'''#!/usr/bin/env bash
printf '%s' "${STUB_HTTP_CODE:-200}"
'''


@pytest.fixture
def stub_bin(tmp_path: Path) -> Path:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name, body in (("aws", STUB_AWS), ("curl", STUB_CURL)):
        p = bin_dir / name
        p.write_text(body, encoding="utf-8")
        p.chmod(0o755)
    return bin_dir


def _run(script: str, env: dict, stub_bin: Path, tmp_path: Path, cwd: Path | None = None) -> subprocess.CompletedProcess:
    out = tmp_path / "github_output"
    summary = tmp_path / "summary.md"
    out.touch()
    summary.touch()
    full = {
        "PATH": f"{stub_bin}:{os.environ['PATH']}",
        "GITHUB_OUTPUT": str(out),
        "GITHUB_STEP_SUMMARY": str(summary),
        "RUNNER_TEMP": str(tmp_path / "runner"),
        "HOME": os.environ.get("HOME", "/tmp"),
    }
    full.update(env)
    (tmp_path / "runner").mkdir(exist_ok=True)
    return subprocess.run(["bash", str(SCRIPTS / script)], env=full, cwd=cwd or tmp_path, capture_output=True, text=True, timeout=60)


BAKE_ENV = {"APP_NAME": "example", "STAGE": "production", "REGION": "us-west-2", "BAKE_SECONDS": "0", "HEALTH_TIMEOUT": "1"}


def test_bake_fails_when_an_alarm_is_firing(stub_bin: Path, tmp_path: Path) -> None:
    env = dict(BAKE_ENV, STUB_ALARMS="example-production-us-west-2-5xx\texample-production-us-west-2-p99", STUB_FIRING="example-production-us-west-2-5xx")
    r = _run("verify-deploy.sh", env, stub_bin, tmp_path)
    assert r.returncode == 1, r.stdout + r.stderr
    assert "::error::alarm(s) in ALARM during bake: example-production-us-west-2-5xx" in r.stderr
    assert "FAILED bake" in (tmp_path / "summary.md").read_text()


def test_bake_passes_when_alarms_stay_ok(stub_bin: Path, tmp_path: Path) -> None:
    env = dict(BAKE_ENV, STUB_ALARMS="example-production-us-west-2-5xx\texample-production-us-west-2-p99", STUB_FIRING="")
    r = _run("verify-deploy.sh", env, stub_bin, tmp_path)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "bake passed: 2 alarm(s)" in r.stdout


def test_bake_warns_but_passes_with_no_alarms(stub_bin: Path, tmp_path: Path) -> None:
    env = dict(BAKE_ENV, STUB_ALARMS="")
    r = _run("verify-deploy.sh", env, stub_bin, tmp_path)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "::warning::no CloudWatch alarms named example-production-us-west-2-*" in r.stdout


def test_health_url_from_terraform_output_wins_over_template(stub_bin: Path, tmp_path: Path) -> None:
    env = dict(BAKE_ENV, STUB_ALARMS="", HEALTH_URL="https://abc.lambda-url.us-west-2.on.aws/", HEALTH_URL_TEMPLATE="https://api.{stage}.example.com/{region}/health")
    r = _run("verify-deploy.sh", env, stub_bin, tmp_path)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "url=https://abc.lambda-url.us-west-2.on.aws/" in (tmp_path / "github_output").read_text()


def test_health_template_renders_stage_and_region(stub_bin: Path, tmp_path: Path) -> None:
    env = dict(BAKE_ENV, STUB_ALARMS="", HEALTH_URL_TEMPLATE="https://api.{stage}.example.com/{region}/health")
    r = _run("verify-deploy.sh", env, stub_bin, tmp_path)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "url=https://api.production.example.com/us-west-2/health" in (tmp_path / "github_output").read_text()


def test_health_failure_fails_the_deploy(stub_bin: Path, tmp_path: Path) -> None:
    env = dict(BAKE_ENV, STUB_ALARMS="", HEALTH_URL="https://x/health", STUB_HTTP_CODE="503")
    r = _run("verify-deploy.sh", env, stub_bin, tmp_path)
    assert r.returncode == 1
    assert "::error::health check failed" in r.stderr


ARTIFACT_ENV = {"APP_NAME": "example", "IMAGE_TAG": "deadbeef", "REGION": "us-west-2", "DEPLOY_TARGET": "lambda", "ARTIFACT_BUCKET": "example-artifacts-111111111111"}


def test_tag_run_refuses_a_commit_that_never_reached_staging(stub_bin: Path, tmp_path: Path) -> None:
    env = dict(ARTIFACT_ENV, WAIT_SECONDS="0", STUB_OBJECT_EXISTS="0")
    r = _run("wait-for-artifact.sh", env, stub_bin, tmp_path)
    assert r.returncode == 1
    assert "A production tag must point at a commit that already reached staging" in r.stderr


def test_present_zip_is_downloaded_and_unpacked(stub_bin: Path, tmp_path: Path) -> None:
    zip_path = tmp_path / "function.zip"
    with zipfile.ZipFile(zip_path, "w") as zf:
        zf.writestr("app.py", "def handler(event, context):\n    return {'statusCode': 200}\n")
    env = dict(ARTIFACT_ENV, WAIT_SECONDS="30", STUB_OBJECT_EXISTS="1", STUB_ZIP=str(zip_path))
    r = _run("wait-for-artifact.sh", env, stub_bin, tmp_path)
    assert r.returncode == 0, r.stdout + r.stderr
    outputs = dict(line.split("=", 1) for line in (tmp_path / "github_output").read_text().splitlines() if "=" in line)
    assert outputs["artifact_path"].endswith("/artifact/function.zip")
    assert (Path(outputs["artifact_dir"]) / "app.py").exists()


def test_container_artifact_outputs_the_regional_image_uri(stub_bin: Path, tmp_path: Path) -> None:
    (tmp_path / "Dockerfile").write_text("FROM scratch\n")
    env = {"APP_NAME": "example", "IMAGE_TAG": "deadbeef", "REGION": "eu-west-1", "DEPLOY_TARGET": "terraform", "ECR_REPOSITORY": "example", "WAIT_SECONDS": "0", "STUB_IMAGE_EXISTS": "1"}
    r = _run("wait-for-artifact.sh", env, stub_bin, tmp_path, cwd=tmp_path)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "image_uri=111111111111.dkr.ecr.eu-west-1.amazonaws.com/example:deadbeef" in (tmp_path / "github_output").read_text()
