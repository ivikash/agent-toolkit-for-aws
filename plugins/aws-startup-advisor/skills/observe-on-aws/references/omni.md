# CloudWatch Omni for a startup

What the Omni path adds on top of the CloudWatch minimum set, in the order it is done, and what it
does not change. The full procedures live in two sibling skills and this file points at them
rather than restating them:

- Setup (Domain, Space, grants, profiles, instrumentation):
  `skills/specialized-skills/operations-skills/setting-up-cloudwatch-observability/references/cloudwatch-omni/spaces-and-domains.md`,
  `access-grants.md`, `access-profiles.md` in the same folder.
- Use (alerts, dashboards, queries, concepts):
  `plugins/aws-core/skills/aws-observability/references/cloudwatch-omni/alerts.md`,
  `dashboards.md`, `concepts.md`, `query/promql-metrics.md`, `query/sql-logs-traces.md`.

## Contents

- [Facts to state every time](#facts-to-state-every-time)
- [Eligibility and the trial](#eligibility-and-the-trial)
- [Setup order](#setup-order)
- [The two alerts](#the-two-alerts)
- [What the deploy bake does not read](#what-the-deploy-bake-does-not-read)
- [A dashboard in Omni](#a-dashboard-in-omni)
- [Rollback](#rollback)

## Facts to state every time

From `concepts.md`, and non-negotiable in any answer that touches Omni:

- Omni is a **separate service** beside CloudWatch, not a replacement. Log groups, metric
  namespaces, alarms and CloudWatch dashboards keep working unchanged.
- The setup order is **Domain, then Space, then grants, then telemetry in, then instrumentation**.
- **Telemetry sent before a Space exists appears to succeed while delivering nowhere the user can
  see.** Create the Space first.
- Access profiles are **conditional**: needed when something asynchronous (an alert, an integration)
  acts in the Space. The two alerts below run under one, so the Omni path needs it.
- One Domain per account, one Space per account per Region.

## Eligibility and the trial

Omni bills three things, all at standard CloudWatch rates for the first two: telemetry ingested,
telemetry stored, and queries above an allowance. Dashboards and alerts are included within
quotas. The trial is $1,000 of OpenTelemetry ingestion credit (OTel logs, OTel metrics, spans) for
30 days, applied once when Omni is enabled, available to up to 10 accounts per Organization, and
**not every account is eligible**: the console shows eligibility when Omni is enabled. Say that
plainly. A startup on Activate credits sees Omni's ingestion covered twice over in month one, and
by Activate alone after.

The ongoing allowance is separate from the trial: each month the account can scan up to 5 times
its total log and span ingestion at no cost, then $0.005 per GB scanned. A seed-stage service
never reaches it. `costs.md` has the numbers.

## Setup order

Each step is one procedure in `spaces-and-domains.md` and `access-grants.md`. This skill runs them
in this order and checks each before the next:

1. **Domain** (once per account). `aws cloudwatchomni list-domains` first. Create with
   `create-domain`, IAM as the identity provider for a team without Identity Center. The domain
   name becomes the team's sign-in URL.
2. **Space** (once per account per Region). `list-spaces` filtered to the Region first. Create with
   `create-space`, which needs the data-access role and the evaluation role the procedure
   describes. `create-space` **does not verify the role can be assumed**: a wrong trust policy is
   accepted at create time and fails at first use. Read the Space back with `get-space` and run one
   query before calling it done.
3. **Grants.** One access grant per teammate (or group) on the Space, READ for most, and the
   ALERT trust grant plus a telemetry-read grant for the access profile the alerts run under.
4. **Telemetry in.** The collector from `instrumentation.md`. The same CloudWatch OTLP endpoints,
   nothing Omni-specific.
5. **Instrumentation.** The SDK settings from `instrumentation.md`.

Then the CloudWatch minimum set (alarms, composite, dashboard) exactly as on the other path, and
the two Omni alerts.

## The two alerts

Omni alerts watch a query, PromQL for metrics, SQL for log and trace conditions. The startup set
is two PromQL alerts on the span-derived RED metrics the Space computes from the traces, because
those are already aggregated and cheap at any traffic level:

| Alert | Query | Threshold |
|---|---|---|
| `<app>-<stage>-error-rate` | `sum(sum_over_time({__name__="traces.span.metrics.calls", "@resource.service.name"="<app>", "status.code"="ERROR"}[5m])) / sum(sum_over_time({__name__="traces.span.metrics.calls", "@resource.service.name"="<app>"}[5m]))` | A **fraction** (0.02 for 2 percent), the same number as the CloudWatch alarm divided by 100 |
| `<app>-<stage>-p99-latency` | `histogram_quantile(0.99, rate({__name__="traces.span.metrics.duration", "@resource.service.name"="<app>"}[5m]))` | **Seconds** (1.5 for 1,500 ms), the same number as the CloudWatch alarm divided by 1000 |

Bodies for `create-alert --cli-input-json` are in
[`templates/omni/alert-error-rate.json`](templates/omni/alert-error-rate.json) and
[`templates/omni/alert-p99-latency.json`](templates/omni/alert-p99-latency.json). Follow the
create procedure in `alerts.md` exactly, in particular:

- **Ground each query by running it once** in the Space before proposing it. The metric names
  above are the Space's span-derived RED metrics, present once traces flow. An alert on a name that
  does not resolve sits at `NODATA` forever and never errors.
- `traces.span.metrics.calls` is a **delta Sum**, read with `sum_over_time`, never `rate()`.
  `traces.span.metrics.duration` is a native histogram, read with `histogram_quantile` on the base
  name, no `_bucket`, no `by (le)`.
- `language` is set to `PROMQL` explicitly. The comparison stays out of the expression. The `[5m]`
  range is the alert's window. `intervalSeconds` is 300 and `pendingDurationSeconds` 300, so one
  spike does not fire.
- The threshold unit matches the series: a fraction for the ratio, seconds for the duration.
  State both units when confirming.
- **Confirm the exact proposal**, create, and **name the alert back from the response** (`name`,
  `alertId`, `rule.telemetryRule.condition`).
- Notifications go to the same SNS topic as the CloudWatch composite alarm, on `CRITICAL`. One
  topic, two sources.

Two alerts and three alarms on the same symptoms is deliberate: the alarms are what the deploy
bake and the composite page read, the alerts are what Omni's investigation agent opens on. Say so,
and do not create a third set.

## What the deploy bake does not read

`deploy-from-github`'s bake calls `cloudwatch describe-alarms` with the alarm prefix
`<app>-<stage>-<region>-`. Omni alerts
are a different resource under a different API, and the bake does not see them. The CloudWatch
alarms stay, on both paths. A user who asks to "move the alarms into Omni" is told what that
breaks before anything is deleted.

## A dashboard in Omni

Included within quotas, built from a `panels[]` body through `dashboards.md`. For a startup the
CloudWatch dashboard from the minimum set is enough on day one. Offer the Omni dashboard when the
team has started asking questions the CloudWatch one does not answer, and build it from the RED
panel templates in `dashboards.md` (request rate, error rate, p99, one row of latency quantiles).

## Rollback

Deleting a Space is destructive to the Space's own objects (alerts, dashboards, views, grants),
never to the telemetry, which is CloudWatch's. It needs the user's confirmation. Deleting the Domain
removes the sign-in URL. Neither touches the CloudWatch alarms, the dashboard or the collector.
