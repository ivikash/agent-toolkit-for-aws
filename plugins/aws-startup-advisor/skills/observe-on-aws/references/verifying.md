# Verifying: every signal arrives, every alarm can fire

Work the table top to bottom. A row that cannot be checked is reported as not verified, not as
done. Replace `<app>`, `<stage>` and `<region>`.

## Contents

- [Collector](#collector)
- [Logs](#logs)
- [Traces](#traces)
- [Metrics](#metrics)
- [Alarms: the drill](#alarms-the-drill)
- [Dashboard](#dashboard)
- [Omni](#omni)
- [Troubleshooting](#troubleshooting)

## Collector

| Check | Command | Pass |
|---|---|---|
| The agent started its pipelines | `aws logs tail /ecs/<app>-<stage>-collector --since 10m` (ECS) or the instance's agent log (EC2) | Lines naming the `traces`, `metrics` and `logs` pipelines. An agent that reports `running` without them is too old (`instrumentation.md`, tag floor). |
| The app reaches it | Application log after a request | No OTLP connection errors. On the CloudWatch agent path every OTLP error is a real problem. |

Lambda has no collector. Skip to Logs.

## Logs

| Check | Command | Pass |
|---|---|---|
| A log record with the service name | `aws logs start-query --log-group-name <otel group> --start-time $(date -d '-15 min' +%s) --end-time $(date +%s) --query-string 'fields @timestamp, severity_text, body, resource.attributes.service.name \| sort @timestamp desc \| limit 5'` then `get-query-results` | Rows with `resource.attributes.service.name = <app>` |
| Retention applied | `aws logs describe-log-groups --log-group-name-prefix <prefix> --query 'logGroups[].[logGroupName,retentionInDays]'` | Every group shows the agreed number, none shows `None` |

## Traces

| Check | Command | Pass |
|---|---|---|
| Spans arrive | Console: CloudWatch, Application Signals, Transaction Search, filter `service.name = <app>`. Or `aws xray get-trace-summaries --start-time $(date -d '-15 min' +%s) --end-time $(date +%s) --query 'TraceSummaries[0:3].[Id,Duration]'` | At least one trace from the last 15 minutes with the service name |
| `service.version` present | Open one trace, read the resource attributes | The commit SHA of the running version |

If Transaction Search was enabled after the first traces, they are not searchable. Send new ones.

## Metrics

| Check | Command | Pass |
|---|---|---|
| Edge metrics exist (they drive the alarms) | `aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB --metric-name RequestCount --dimensions Name=LoadBalancer,Value=<suffix> --start-time $(date -u -d '-1 hour' +%FT%TZ) --end-time $(date -u +%FT%TZ) --period 300 --statistics Sum` (or `AWS/Lambda` `Invocations`) | Datapoints in the last hour |
| OTel metrics arrive | Console: CloudWatch, Metrics, Query Studio, PromQL `{__name__=~"http.server.request.duration.*", "@resource.service.name"="<app>"}` | A series. Exact names depend on the SDK's semantic conventions version, which is why the query uses a prefix match. |

## Alarms: the drill

Every alarm is driven to `ALARM` once, so the page is proven before the first real incident.

```sh
for name in error-rate p99-latency; do
  aws cloudwatch set-alarm-state --alarm-name "<app>-<stage>-<region>-${name}" \
    --state-value ALARM --state-reason "observe-on-aws drill $(date -u +%FT%TZ)"
done
sleep 20
aws cloudwatch describe-alarms --alarm-name-prefix "<app>-<stage>-<region>-" \
  --query 'CompositeAlarms[].[AlarmName,StateValue]' --output table
```

| Pass |
|---|
| The composite alarm `<prefix>health` shows `ALARM` |
| The email arrives (the SNS subscription was confirmed: `aws sns list-subscriptions-by-topic --topic-arn <arn>` shows no `PendingConfirmation`) |
| Within a few minutes the metric alarms return to `OK` on their own, because the real metric is fine, and the composite follows |

Do the drill in staging first. In production, do it once, outside a deploy, and tell the user when.

## Dashboard

Open `https://<region>.console.aws.amazon.com/cloudwatch/home?region=<region>#dashboards:name=<app>-<stage>-<region>`.

| Pass |
|---|
| The alarm strip shows three alarms, all `OK` after the drill |
| Error rate and p99 charts have data and a threshold line |
| Requests per minute matches what the edge reports |
| The errors panel, when configured, lists records or an honest "no results" |

## Omni

| Check | Command | Pass |
|---|---|---|
| The Space exists in the Region | `aws cloudwatchomni list-spaces --region <region> --query "items[?region=='<region>']"` | One Space |
| The Space's role works | `aws cloudwatchomni get-space --space-id <id>` and one query (below) | The query returns rows. `create-space` never verified that the role can be assumed, so this is the first real test. |
| Logs in the Space | SQL over `logs.default`: `` SELECT COUNT(*) FROM logs.default WHERE `@timestamp` > NOW() - INTERVAL '15' MINUTE AND `resource.attributes.service.name` = '<app>' `` through the Omni query procedure in `aws-observability` | A non-zero count |
| Span RED metrics present | PromQL in the Space: `sum(sum_over_time({__name__="traces.span.metrics.calls", "@resource.service.name"="<app>"}[5m]))` | A number. This is the grounding for the error-rate alert. |
| Alerts created | `aws cloudwatchomni list-alerts --space-id <id>` | `<app>-<stage>-error-rate` and `<app>-<stage>-p99-latency`, each with the stored query and threshold |
| Teammates can sign in | The Domain URL, one teammate | They see the Space |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No OTLP errors, no telemetry anywhere | The collector exports to the Region in its config, not the one you are looking at. Or the agent is too old to start the OTLP receiver. | Check `agent.region` in the config, and the agent tag against the floor. |
| `AccessDenied` in the collector log on every export | `CloudWatchAgentServerPolicy` on the execution role instead of the task role (ECS), or missing on the instance profile. | Move it to the task role. |
| App logs `connection refused` to 4318 | No collector in the task, or the agent listens on 4316 only (Application Signals config). | Add the sidecar with the OTLP config. |
| Traces in CloudWatch but nothing in the Space | Telemetry started before the Space existed, or the Space is in another Region. | Create the Space, then send new telemetry. Filter `list-spaces` by Region. |
| Omni alert stuck at `NODATA` | The metric name does not resolve in this Space (never grounded), or no traces are flowing yet. | Run the alert's query by hand. Fix the name, or wait for traces. |
| Alarm stuck at `INSUFFICIENT_DATA` | No requests yet, or wrong dimension value (an ARN instead of the `arn_suffix`). | `describe-alarms` shows the dimensions; compare with `aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn'` (the suffix is the part after `loadbalancer/`). |
| Latency alarm never fires in a real incident | Threshold in the wrong unit. | The module compares in milliseconds on both computes. A hand-edited alarm on ALB `TargetResponseTime` must be in seconds. |
| No email on the drill | Subscription never confirmed. | The confirmation mail went to the address at creation. Resend with `aws sns subscribe`. |
| Deploy bake passes with "no alarms" warning | The alarms were created under a different prefix, or in another Region. | Names must start with `<app>-<stage>-<region>-` in the Region of the deploy. |
| Costs higher than the estimate | Log volume. | `aws logs describe-log-groups` sorted by `storedBytes` finds the chatty group. Lower its log level or its retention. |
