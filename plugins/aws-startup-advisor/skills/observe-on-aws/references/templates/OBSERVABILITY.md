# Observability

What is watched in production, why those numbers, and what to do when something fires. Generated
by the `observe-on-aws` skill on `{{DATE}}`. Edit freely, it is yours.

## What is watched

Stage `{{STAGE}}`, Region `{{REGION}}`, compute `{{COMPUTE}}`.

| Alarm | Fires when | Threshold | Evidence |
|---|---|---|---|
| `{{APP_NAME}}-{{STAGE}}-{{REGION}}-error-rate` | More than {{ERROR_RATE_PERCENT}}% of requests fail, 2 of 3 minutes | {{ERROR_RATE_PERCENT}}% | {{ERROR_RATE_EVIDENCE}} |
| `{{APP_NAME}}-{{STAGE}}-{{REGION}}-p99-latency` | p99 above {{P99_LATENCY_MS}} ms, 2 of 3 minutes | {{P99_LATENCY_MS}} ms | {{P99_EVIDENCE}} |
| `{{APP_NAME}}-{{STAGE}}-{{REGION}}-{{SATURATION_NAME}}` | {{SATURATION_MEANING}} | 1 | Any is too many |

`{{APP_NAME}}-{{STAGE}}-{{REGION}}-health` is the one alarm that pages. It fires when any of the
three does, and notifies `{{SNS_TOPIC_ARN}}` (currently: {{ALERT_EMAIL}}).

{{THRESHOLD_REVIEW: when thresholds were provisional: "Thresholds were set without traffic history
on {{DATE}}. Review them on {{REVIEW_DATE}} against two weeks of data." Otherwise delete this line.}}

## Where to look

- Dashboard: `{{DASHBOARD_NAME}}` in the CloudWatch console for `{{REGION}}`. Thirty seconds every
  morning.
- Logs: group(s) `{{LOG_GROUPS}}`, retention {{RETENTION_DAYS}} days.
- Traces: CloudWatch Transaction Search, filter `service.name = {{APP_NAME}}`.
{{OMNI_LINE: when Omni is set up: "- Omni: {{DOMAIN_URL}}, Space {{SPACE_ID}}. SQL over logs and
traces, PromQL over metrics. Alerts `{{APP_NAME}}-{{STAGE}}-error-rate` and
`{{APP_NAME}}-{{STAGE}}-p99-latency` notify the same topic." Otherwise delete this line.}}

Every signal carries `service.version` = the deployed commit SHA, so a chart that changes shape at
a deploy names the commit.

## When an alarm fires

1. Open the dashboard. Which of the three is it, and when did it start?
2. Did a deploy happen then? `gh run list --workflow deploy.yml --limit 5`. If yes, roll back:
   `gh workflow run deploy.yml --ref <previous tag> -f stage=production`. Investigate after.
3. If not a deploy: the errors panel on the dashboard (or Omni) shows the failing requests. The
   trace for one of them shows where the time or the error is.
4. Stuck for more than 30 minutes: `operate-on-aws` runs an investigation with AWS DevOps Agent.
5. Afterwards, write three lines in this file under "Incidents": what, why, what changed.

## How telemetry flows

The application runs the OpenTelemetry SDK (ADOT), configured by environment variables
(`OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`, sampler). {{COLLECTOR_LINE: ECS/EC2/EKS: "A
CloudWatch agent sidecar receives OTLP on localhost:4318 and exports logs, metrics and traces to
CloudWatch's OTLP endpoints with the task role." Lambda: "The ADOT Lambda layer exports traces to
the function's X-Ray receiver, and logs go to the function's log group."}} The alarms read the
{{COMPUTE}}'s own metrics, which exist without any instrumentation.

## Changing things

- **A threshold:** `error_rate_percent` or `p99_latency_ms` in the observability module's
  variables, then apply. Write the new evidence in the table above.
- **Who gets paged:** subscribe to `{{SNS_TOPIC_ARN}}` (email, Slack via AWS Chatbot, a pager).
- **Sampling:** `OTEL_TRACES_SAMPLER_ARG` on the application. 0.1 in production is the default.
- **Retention:** `aws logs put-retention-policy`, or `retention_in_days` in the Terraform. Lowering
  it deletes older data.

## When to add more

From `architect-for-startups`: the first outage that takes more than 30 minutes to diagnose,
three or more services calling each other, a SOC 2 audit (90-day retention everywhere), or a
CloudWatch bill over $500 a month (audit log volume first). Not before.

## Incidents

| Date | What | Why | What changed |
|---|---|---|---|
