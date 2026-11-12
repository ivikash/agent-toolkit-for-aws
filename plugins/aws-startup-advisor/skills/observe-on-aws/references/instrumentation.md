# Instrumentation: once, with OpenTelemetry, to CloudWatch

Three parts, in this order: the SDK settings on the application, the collector next to it, the
retention on its log groups. The per-language and per-platform mechanics (how the ADOT SDK gets
loaded into a Python, Node.js, Java or .NET process on ECS, EKS, EC2 or Lambda) are written once
in the `setting-up-cloudwatch-observability` skill, and this skill calls into them rather than
copying them. Follow the guide for the user's runtime and language, with this skill's resource
attributes applied.

## Contents

- [Rules shared with the guides](#rules-shared-with-the-guides)
- [1. SDK settings](#1-sdk-settings)
- [2. The collector, per runtime](#2-the-collector-per-runtime)
- [3. Retention](#3-retention)
- [AI agents](#ai-agents)
- [Order on the Omni path](#order-on-the-omni-path)

## Rules shared with the guides

- **Never modify application source.** Instrumentation is a layer, a sidecar, an init container, a
  dependency file, and environment variables. Edit infrastructure as code, Dockerfiles, task
  definitions, function configuration, and the deploy pipeline's Terraform. Present the diff. Do
  not run `terraform apply`, `aws ecs update-service` or `aws lambda update-function-configuration`
  without the user: on a repository that uses `deploy-from-github`, the pipeline applies it.
- **No Application Signals variables** (`OTEL_AWS_APPLICATION_SIGNALS_*`, `OTEL_AWS_SERVICE_EVENTS_*`,
  port 4316) on this path. On **Lambda** set `OTEL_AWS_APPLICATION_SIGNALS_ENABLED=false` explicitly:
  the layer's wrapper defaults it to true when unset.
- **No export endpoint on the SDK.** The ADOT SDK defaults to the collector beside it,
  `localhost:4318` (Python, Node.js, .NET) or `localhost:4317` (Java). Set
  `OTEL_EXPORTER_OTLP_ENDPOINT` only to reach a destination the files show.
- **IAM follows the destination.** The application gets no observability permissions. The collector
  gets `CloudWatchAgentServerPolicy` on its task role (ECS), instance profile (EC2) or IRSA role
  (EKS). On Lambda the execution role gets `xray:PutTraceSegments` and `xray:PutTelemetryRecords`
  (`AWSXRayDaemonWriteAccess`), because the layer exports to the function's X-Ray receiver.

## 1. SDK settings

[`templates/otel/sdk.env`](templates/otel/sdk.env), on the application container, process or
function, in every language:

| Variable | Value | Why |
|---|---|---|
| `OTEL_SERVICE_NAME` | `<app>` | The service identity every signal carries. Omni's `@resource.service.name`. |
| `OTEL_RESOURCE_ATTRIBUTES` | `deployment.environment.name=<stage>,service.version=<sha>,service.namespace=<app>` | Stage separates staging from production in every query. `service.version` is the commit the deploy pipeline passes as `image_tag`, so a deploy is a visible step in every chart and a regression names its commit. |
| `OTEL_TRACES_SAMPLER` | `parentbased_traceidratio` | Sample at the root, keep whole traces. |
| `OTEL_TRACES_SAMPLER_ARG` | `1.0` in staging, `0.1` in production, or the ratio the cost estimate supports | Spans are priced per GB. Ten percent of a small service's traces is enough to debug with. |

The language guide adds the loader variables (a `-javaagent`, `NODE_OPTIONS`, `opentelemetry-instrument`,
`CORECLR_*`) and nothing else about export.

## 2. The collector, per runtime

The CloudWatch agent is the default collector: it receives OTLP on 4317 and 4318 and exports every
signal (traces, metrics **and logs**) to CloudWatch's OTLP endpoints with the task or instance
role. Its whole configuration is
[`templates/otel/cloudwatch-agent-otlp.json`](templates/otel/cloudwatch-agent-otlp.json), with the
Region filled in. Do not add an `application_signals` section to it.

| Runtime | Collector | Guide |
|---|---|---|
| ECS (Fargate or EC2) | Sidecar container `public.ecr.aws/cloudwatch-agent/cloudwatch-agent:<tag>` (1.300070.0b1586 or later, never `:latest`) in the same task, config in `CW_CONFIG_CONTENT`, `essential = false`, its own log group with 7-day retention, `CloudWatchAgentServerPolicy` on the **task** role. Check the task-level CPU and memory have room for it. | `skills/specialized-skills/operations-skills/setting-up-cloudwatch-observability/references/cloudwatch-omni/instrumentation/collector-ecs.md` |
| EKS | CloudWatch agent by Helm with the OTLP receiver, IRSA role with `CloudWatchAgentServerPolicy`. Not the `amazon-cloudwatch-observability` add-on. | `.../instrumentation/collector-eks.md` |
| EC2 | CloudWatch agent on the instance with the `opentelemetry` section, `CloudWatchAgentServerPolicy` on the instance profile. | `.../instrumentation/collector-ec2.md` |
| Lambda | None. The ADOT Lambda layer plus `AWS_LAMBDA_EXEC_WRAPPER`, active tracing on, and the two X-Ray permissions on the execution role. Logs go to the function's log group as they always did. | `.../instrumentation/lambda-<language>.md` |

Paths are under
`skills/specialized-skills/operations-skills/setting-up-cloudwatch-observability/references/cloudwatch-omni/instrumentation/`
in the toolkit. In a standalone install of this plugin that folder is not present: install the
`setting-up-cloudwatch-observability` skill from the toolkit's `skills/` tree, or read the same
material in the AWS documentation's "Send application telemetry" page for CloudWatch Omni.

Verification of the collector before anything else: the agent's log stream shows its `traces`,
`metrics` and `logs` pipelines started. An older agent reports `running` while starting no OTLP
listener, which is why the tag floor matters.

## 3. Retention

For every log group the app writes to, including the collector's own:

```sh
aws logs put-retention-policy --log-group-name <group> --retention-in-days <7|30|90>
```

Per group, after the user agreed to that group's number (`minimum-set.md`, "Retention"). In
Terraform roots, `retention_in_days` on `aws_cloudwatch_log_group` is the same thing and belongs
in the application's own infrastructure code. The `deploy-from-github` Lambda root already sets it
from `log_retention_days`.

## AI agents

When the application is an agent built on Strands, LangChain, LangGraph, CrewAI, OpenAI Agents or
Vercel AI, instrumentation happens at the framework layer so that model calls, tool calls and
agent steps become spans with the attributes Omni's agent evaluation reads. The
`setting-up-cloudwatch-observability` skill has a dedicated guide:
`skills/specialized-skills/operations-skills/setting-up-cloudwatch-observability/references/cloudwatch-omni/omni-agents-instrumentation/omni-agents-instrumentation.md`.
Use it instead of the per-language guides. The collector, retention and alarms in this file still
apply.

## Order on the Omni path

Domain, Space, grants, **then** the collector, **then** the SDK. Telemetry sent before a Space
exists lands in CloudWatch and is invisible in Omni until a Space exists, and nothing warns. Confirm
with `aws cloudwatchomni list-spaces --region <region> --query "items[?region=='<region>']"`
before the first export. `omni.md` has the setup.
