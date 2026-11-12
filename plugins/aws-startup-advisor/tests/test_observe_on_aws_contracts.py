"""Contracts for the observe-on-aws skill.

The alarm-name prefix is a contract with deploy-from-github's bake, so the Terraform
module, the references and the deploy skill's script must spell it the same way. The
thresholds have no defaults (a guessed threshold is the one thing the skill refuses to do).
The Omni alert templates are valid JSON once their placeholders are filled, read PromQL
with the instrument-correct functions, keep the comparison out of the expression, and use
the field names the aws-observability reference documents. The SDK template never sets an
export endpoint or an Application Signals variable, and the collector config has no
application_signals section.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import yaml

PLUGIN_ROOT = Path(__file__).resolve().parent.parent
SKILL = PLUGIN_ROOT / "skills" / "observe-on-aws"
REFS = SKILL / "references"
TEMPLATES = REFS / "templates"
MODULE = TEMPLATES / "terraform" / "observability"
DEPLOY_VERIFY = PLUGIN_ROOT / "skills" / "deploy-from-github" / "references" / "templates" / "scripts" / "ci" / "verify-deploy.sh"


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _filled(template: Path) -> dict:
    text = re.sub(r"\{\{[A-Z0-9_]+\}\}", "1", _read(template))
    return json.loads(text)


# ---------------------------------------------------------------- frontmatter


def test_frontmatter_name_matches_directory_and_routes_away() -> None:
    fm = yaml.safe_load(_read(SKILL / "SKILL.md").split("---", 2)[1])
    assert fm["name"] == "observe-on-aws"
    assert len(fm["description"]) <= 1024
    for sibling in ("aws-observability", "setting-up-cloudwatch-observability", "operate-on-aws", "architect-for-startups", "deploy-from-github"):
        assert sibling in fm["description"], sibling


# ---------------------------------------------------------------- the prefix contract


def test_alarm_prefix_is_identical_in_module_references_and_deploy_bake() -> None:
    main_tf = _read(MODULE / "main.tf")
    assert 'prefix = "${var.app_name}-${var.stage}-${var.region}-"' in main_tf
    bake = _read(DEPLOY_VERIFY)
    assert 'prefix="${APP_NAME}-${STAGE}-${REGION}-"' in bake
    for ref in ("minimum-set.md", "omni.md"):
        assert "<app>-<stage>-<region>-" in _read(REFS / ref), ref


def test_only_the_composite_alarm_has_actions() -> None:
    main_tf = _read(MODULE / "main.tf")
    metric_alarms = re.findall(r'resource "aws_cloudwatch_metric_alarm" "(\w+)" \{(.*?)\n\}', main_tf, re.S)
    assert {name for name, _ in metric_alarms} == {"error_rate", "p99_latency", "saturation"}
    for name, body in metric_alarms:
        assert "alarm_actions" not in body, f"{name} must not page on its own"
    composite = re.search(r'resource "aws_cloudwatch_composite_alarm" "health" \{(.*?)\n\}', main_tf, re.S).group(1)
    assert "alarm_actions = [aws_sns_topic.alerts.arn]" in composite
    assert composite.count("ALARM(") == 3


def test_thresholds_have_no_defaults() -> None:
    variables = _read(MODULE / "variables.tf")
    for name in ("error_rate_percent", "p99_latency_ms"):
        block = re.search(rf'variable "{name}" \{{(.*?)\n\}}', variables, re.S).group(1)
        assert "default" not in block, f"{name} must be grounded, never defaulted"


def test_alb_latency_is_converted_to_milliseconds() -> None:
    main_tf = _read(MODULE / "main.tf")
    assert 'latency_to_ms   = local.is_alb ? "latency * 1000" : "latency"' in main_tf
    assert "ALB `TargetResponseTime` is seconds" in _read(REFS / "minimum-set.md")


def test_module_tests_cover_both_computes() -> None:
    tftest = _read(MODULE / "tests" / "observability.tftest.hcl")
    for run in ("alb_names_units_and_paging", "lambda_names_and_units", "no_dashboard"):
        assert f'run "{run}"' in tftest


# ---------------------------------------------------------------- Omni alert templates


def test_omni_alert_templates_are_valid_and_follow_the_alerts_reference() -> None:
    for name, metric, func in (
        ("alert-error-rate.json", "traces.span.metrics.calls", "sum_over_time"),
        ("alert-p99-latency.json", "traces.span.metrics.duration", "histogram_quantile"),
    ):
        body = _filled(TEMPLATES / "omni" / name)
        rule = body["rule"]["telemetryRule"]
        assert rule["query"]["language"] == "PROMQL"
        expr = rule["query"]["expression"]
        assert metric in expr and func in expr
        assert "[5m]" in expr, "a PromQL alert carries its own range"
        assert not re.search(r"[<>]=?\s*\d", expr), "the comparison stays out of the expression"
        assert "rate({__name__=\"traces.span.metrics.calls\"" not in expr, "calls is a delta Sum, never rate()"
        assert "_bucket" not in expr and "by (le)" not in expr
        assert rule["condition"]["thresholdMode"] == "FIELD_VALUE"
        assert rule["condition"]["comparator"] == "GT"
        assert rule["evaluation"]["intervalSeconds"] == 300
        assert rule["evaluation"]["pendingDurationSeconds"] % rule["evaluation"]["intervalSeconds"] == 0
        assert rule["noData"]["treatAs"] == "OK"
        assert body["notificationRules"][0]["target"]["type"] == "sns"
        assert "warningThreshold" not in rule["condition"], "one tier until asked"


# ---------------------------------------------------------------- OTel templates


def test_sdk_env_sets_identity_and_sampling_and_nothing_about_export() -> None:
    env = _read(TEMPLATES / "otel" / "sdk.env")
    keys = {line.split("=", 1)[0] for line in env.splitlines() if line and not line.startswith("#")}
    assert keys == {"OTEL_SERVICE_NAME", "OTEL_RESOURCE_ATTRIBUTES", "OTEL_TRACES_SAMPLER", "OTEL_TRACES_SAMPLER_ARG"}
    assert "service.version=" in env and "deployment.environment.name=" in env
    assert "OTEL_EXPORTER_OTLP" not in env
    assert "OTEL_AWS_APPLICATION_SIGNALS" not in env


def test_collector_config_has_otlp_receiver_and_no_application_signals() -> None:
    text = _read(TEMPLATES / "otel" / "cloudwatch-agent-otlp.json")
    config = json.loads(text.replace("{{REGION}}", "us-west-2"))
    otlp = config["opentelemetry"]["collect"]["otlp"]
    assert otlp == {"grpc_endpoint": "0.0.0.0:4317", "http_endpoint": "0.0.0.0:4318"}
    assert "application_signals" not in text
    assert "4316" not in text


def test_instrumentation_states_the_lambda_application_signals_rule() -> None:
    text = _read(REFS / "instrumentation.md")
    assert "OTEL_AWS_APPLICATION_SIGNALS_ENABLED=false" in text
    assert "Never modify application source" in text


def test_omni_reference_states_the_space_first_warning() -> None:
    text = _read(REFS / "omni.md")
    assert "Domain, then Space, then grants, then telemetry in, then instrumentation" in text
    assert "appears to succeed while delivering nowhere the user can" in text
    assert "bake does not see them" in text or "the bake does not read" in text


# ---------------------------------------------------------------- cross-skill routing


def test_deploy_skill_bake_message_and_observe_skill_agree_on_who_creates_alarms() -> None:
    bake = _read(DEPLOY_VERIFY)
    assert "observe-on-aws creates them" in bake
    design = _read(PLUGIN_ROOT / "skills" / "deploy-from-github" / "references" / "pipeline-design.md")
    assert "observe-on-aws" in design
