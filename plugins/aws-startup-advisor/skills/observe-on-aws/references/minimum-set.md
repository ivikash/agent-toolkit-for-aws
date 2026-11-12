# The minimum set

Three alarms on symptoms, one composite that pages, one dashboard, retention on every log group.
[`templates/terraform/observability/`](templates/terraform/observability/) creates all of it per
stage and Region. This file explains each piece and how to ground the two thresholds.

## Contents

- [Why symptoms, and why from the edge](#why-symptoms-and-why-from-the-edge)
- [The three alarms](#the-three-alarms)
- [One page](#one-page)
- [The dashboard](#the-dashboard)
- [Retention](#retention)
- [Grounding a threshold](#grounding-a-threshold)
- [Naming](#naming)
- [What is deliberately not here](#what-is-deliberately-not-here)

## Why symptoms, and why from the edge

Users feel three things: requests fail, requests are slow, requests do not get through. CPU at
80 percent is a cause that may or may not become a symptom. So the alarms watch the share of
failed requests, the p99 latency, and whether the service is turning requests away.

The numbers come from the edge, the Application Load Balancer (`AWS/ApplicationELB`) or Lambda
(`AWS/Lambda`), for two reasons. They exist the moment the service exists, with no instrumentation
and no cost. And they measure what the caller saw, not what the application believed it returned.
The OpenTelemetry traces and logs explain *why*, after an alarm fires.

## The three alarms

| Alarm | ALB | Lambda | Fires when |
|---|---|---|---|
| `<prefix>error-rate` | `100 * HTTPCode_Target_5XX_Count / RequestCount` | `100 * Errors / Invocations` | Above `error_rate_percent` for 2 of 3 minutes |
| `<prefix>p99-latency` | `TargetResponseTime` p99, in **seconds**, multiplied by 1000 in metric math | `Duration` p99, already in **milliseconds** | Above `p99_latency_ms` for 2 of 3 minutes |
| `<prefix>unhealthy-hosts` (ALB) / `<prefix>throttles` (Lambda) | `UnHealthyHostCount` Maximum | `Throttles` Sum | At least 1 for 2 of 3 minutes |

Details that matter:

- **Error rate is a ratio, computed in metric math** (`IF(requests > 0, 100 * errors / requests, 0)`),
  so a quiet hour with one error does not fire and a busy hour with many does. A raw 5xx count
  alarm does the opposite.
- **Units.** ALB `TargetResponseTime` is seconds. Lambda `Duration` is milliseconds. The module
  compares both in milliseconds, converting the ALB value with `latency * 1000`, so one threshold
  variable means one thing. A threshold of 500 on a seconds metric is eight minutes, and the alarm
  never fires. The offline test pins this.
- **2 of 3 minutes.** One bad minute does not page. Three minutes of 60-second periods is the
  default, with `datapoints_to_alarm = 2`.
- **Missing data is not breaching.** A service with no traffic at 3 a.m. is not broken. An
  "is anyone home" alarm (zero requests during business hours) is a Series A alarm, not a seed one.
- **Saturation.** For ALB, a target failing its health check is a request that will fail. For
  Lambda, a throttle is a request that did fail. Both are the third symptom.

## One page

The three alarms carry the signal and have **no actions**. The composite alarm `<prefix>health`
is `ALARM(error-rate) OR ALARM(p99-latency) OR ALARM(saturation)`, and it is the only one with
an SNS action. One incident is one page, not three. The SNS topic takes an email on creation and
is where Slack or a pager gets subscribed later.

The deploy-from-github bake reads the three **metric** alarms by prefix, not the composite. A
deploy that pushes error rate up fails its bake even though nobody was paged yet.

## The dashboard

One per stage and Region, named `<app>-<stage>-<region>`, five widgets at most:

1. The alarm strip: the three alarms' current state.
2. Error rate, with the threshold drawn as a line.
3. p99 latency in milliseconds, with the threshold drawn.
4. Requests per minute.
5. When an OpenTelemetry log group is given, the last 50 log records at severity ERROR or above
   (`severity_number >= 17`).

Nothing else until the service has been in production for three months. The first three
dashboards in an account are free. A team that builds the wrong dashboard on day one does not look
at it on day thirty.

## Retention

`Never expire` is the CloudWatch Logs default and the slowest leak on a startup bill: $0.03 per
GB-month, forever, for logs nobody will read after a month. The skill proposes 7 days in staging
and 30 days in production, per group, and applies it only after the user agrees per group, because
lowering retention deletes the older data at once:

```sh
aws logs put-retention-policy --log-group-name <group> --retention-in-days 30
```

While Activate credits cover the account, 90 days everywhere is a defensible choice (`architect-for-startups`,
"Credits consideration"). Record which was chosen and why in `OBSERVABILITY.md`.

## Grounding a threshold

A threshold is a claim about what "normal" is. Make the claim from the service's own two weeks
(`readiness.md`, "Grounding the thresholds"), never from a round number.

1. Compute the hourly error rate and p99 over the window. Note the typical value and the peak on a
   day with no incident.
2. Propose a threshold **above the healthy peak** with room for ordinary variance. For a service
   whose p99 peaked at 820 ms, 1,500 ms gives a clear margin. For an error rate whose healthy peak
   was 0.4 percent, 2 percent is plain. Write the evidence next to the number:
   *"p99 over 14 days peaked at 820 ms, proposed alarm 1,500 ms"*.
3. The user confirms or changes it. Their number wins, with the unit confirmed.
4. **No history** (a new service, or no traffic yet): ask the user for the two numbers. Put
   `(provisional, set <date>, review after two weeks of traffic)` in the alarm descriptions, and a
   dated review item in `OBSERVABILITY.md`.

Never derive a warning tier from a single critical number. One tier, until the user asks for two.

## Naming

Everything carries `<app>-<stage>-<region>-`:

| Object | Name |
|---|---|
| Metric alarms | `<prefix>error-rate`, `<prefix>p99-latency`, `<prefix>unhealthy-hosts` or `<prefix>throttles` |
| Composite alarm | `<prefix>health` |
| Dashboard | `<app>-<stage>-<region>` |
| SNS topic | `<app>-<stage>-alerts` |

The prefix is the contract with the deploy bake.

## What is deliberately not here

- **Anomaly detection alarms.** They need two weeks of baseline and cost three alarm metrics each.
  Add on request after the baseline exists.
- **Custom application metrics as alarm sources.** The OTel metrics are for diagnosis and for
  Omni's PromQL alerts. CloudWatch alarms on the vended edge metrics are enough for the page.
- **Per-endpoint alarms.** Cardinality multiplies alarms and cost. The dashboard's logs panel and
  the traces answer "which endpoint".
- **Synthetics canaries.** Useful, $0.0012 per run, and a second thing to maintain. Offer when the
  health URL exists and the team wants an outside-in check.
- **A dev stage.** Staging and production only, matching `deploy-from-github`.
