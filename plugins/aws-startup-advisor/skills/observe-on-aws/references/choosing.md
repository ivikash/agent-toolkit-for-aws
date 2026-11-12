# Choosing: CloudWatch alone, or CloudWatch with Omni on top

The question is smaller than it sounds. Both paths instrument once with OpenTelemetry and send
the signals to CloudWatch's OTLP endpoints. Both keep the three CloudWatch alarms, the composite
alarm and the dashboard, because the deploy bake reads CloudWatch alarms and the symptom metrics
come from the load balancer or Lambda regardless of instrumentation. Omni is a second way of
reading the same data, through a Space, and it can be added or removed without touching the
telemetry.

## What each gives a two-person team

| | CloudWatch alone | CloudWatch with Omni |
|---|---|---|
| Where you look | The AWS console: Logs Insights, Metrics, X-Ray Transaction Search, the dashboard | One URL outside the console (the Domain's endpoint), plus the console still works |
| Logs | Logs Insights query language, per log group | SQL over `logs.default`, every group at once, joined with traces |
| Traces | Transaction Search, trace map | SQL over `traces.default`, context graph of services and dependencies |
| Metrics | Metrics console, PromQL in Query Studio over OTel metrics | PromQL over the same metrics, plus span-derived RED metrics (`traces.span.metrics.calls`, `traces.span.metrics.duration`) |
| Alarms and alerts | CloudWatch alarms, $0.10 per alarm metric per month | CloudWatch alarms unchanged, plus Omni alerts (SQL or PromQL) at no extra charge within quotas |
| Dashboards | Three free, $3 per month each after | CloudWatch dashboards unchanged, plus Omni dashboards at no extra charge within quotas |
| Investigation | `operate-on-aws` (AWS DevOps Agent, metered) | Omni's investigation agent on every alert, included; `operate-on-aws` still available |
| AI agents in the workload | Traces of model and tool calls, read by hand | Agent evaluation of production traces, scored and queryable |
| Access for teammates | IAM users or Identity Center per person, console sign-in | Domain with IAM or Identity Center, access grants per Space, one sign-in URL |
| Extra cost | None beyond ingestion and storage | Query scans above 5 times monthly log and span ingestion, at $0.005 per GB. Dashboards and alerts included. |
| Trial | None specific | $1,000 of OpenTelemetry ingestion credit for 30 days when the account is eligible, up to 10 accounts per Organization |

## Pick Omni when

- More than one person will look at production, and they are not all comfortable in the console.
- The workload includes an AI agent whose traces need evaluation, not just reading.
- The team already thinks in SQL and PromQL.
- The account is eligible for the trial credit, which pays for the first month of OpenTelemetry
  ingestion either way.

## Pick CloudWatch alone when

- One person owns production and lives in the console already.
- The Region has no Omni (check `aws cloudwatchomni list-domains --region <region>`).
- The account cannot grant the caller Omni permissions and nobody is available to do it this week.
  Set up CloudWatch now and add the Space later over the same data.

## What does not change the answer

- **Cost of telemetry.** Identical: the same bytes land in CloudWatch at the same per-GB rates.
- **The alarms.** Identical, and required on both paths for the deploy bake.
- **The instrumentation.** Identical SDK variables and collector. The one ordering rule is that
  on the Omni path the Space exists before telemetry starts, because telemetry sent before a Space
  exists appears to succeed while delivering nowhere the user can see.

## Reversibility

Adding Omni later: create the Domain and Space (`omni.md`), and the data already in CloudWatch is
queryable through the Space from that moment. Removing Omni: delete the Space (destructive to the
Space's own objects, such as alerts and dashboards, and never to the telemetry, which is CloudWatch's).
Say both of these in CHOOSE so the decision does not feel heavier than it is.

## How to ask

One sentence, with the two facts that decide it: *"Your telemetry and alarms are the same either
way. Omni gives the team one URL with SQL over logs and traces, alerts and dashboards included,
and (if eligible) a $1,000 ingestion credit for the first month. CloudWatch alone is the console
you already know. Which do you want?"* Record the answer and the reason.
