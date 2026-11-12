# Costs: what observability costs a startup

**Last updated:** 2026-11-12. List prices read from the Amazon CloudWatch pricing page and the
CloudWatch Omni pricing page on that date, US East (N. Virginia). Other Regions differ by a few
percent. Re-read the sources before quoting a number more than a quarter old. AWS Activate
credits apply to every CloudWatch line below.

## Ingestion and storage (both paths)

| Item | Rate | Note |
|---|---|---|
| Logs ingested, Standard class | $0.50 per GB | The surprise line. Debug logging left on in production is the usual cause. |
| Logs ingested, Infrequent Access class | $0.25 per GB | Not queryable with Live Tail. Fine for audit-style logs. |
| Logs stored | $0.03 per GB-month, on compressed bytes (about 15 percent of ingested) | `Never expire` makes this grow forever. Retention fixes it. |
| Logs Insights, per GB scanned | $0.005 | Dashboards and ad-hoc queries |
| OpenTelemetry metrics ingested | $0.50 per GB | 15 months of storage included. No per-metric charge, so cardinality is a volume question, not a count question. |
| Classic custom metrics (`PutMetricData`, EMF) | $0.30 per metric per month for the first 10,000 | The old model. Each unique dimension combination is a metric. This skill uses none. |
| Spans ingested | $0.35 per GB for the first 10 TB, then $0.20, then $0.15 | Same rate as Application Signals. Trace indexing for the trace list is a separate per-span charge above the first 1 percent, which is free. |
| Alarms | $0.10 per alarm metric per month, standard resolution | The minimum set is three metric alarms plus one composite ($0.50 per month for the composite) |
| Dashboards | First three free, then $3 per dashboard per month | The minimum set is one |
| CloudWatch free tier, every month | 5 GB of log ingestion, archive and scan, 10 custom metrics, 10 alarms, 3 dashboards, 100,000 traces recorded | A seed-stage staging environment often fits inside it |

## Omni (on top of the above)

| Item | Rate | Note |
|---|---|---|
| Ingestion and storage | Standard CloudWatch rates above | Nothing extra. The same bytes. |
| Query scans, logs and spans | Free up to 5 times the month's log and span ingestion, then $0.005 per GB | Dashboards count toward scan volume. A 5-minute auto-refresh keeps it small. |
| PromQL queries from the API | Per million samples, standard CloudWatch rate | Console PromQL is free. |
| Dashboards and alerts | Included within service quotas | |
| Investigation agent, context graph | Included | |
| Agent evaluation | Amazon Bedrock AgentCore rates | Only when evaluations are run |
| Trial | $1,000 of OTel ingestion credit (OTel logs, OTel metrics, spans) for 30 days, once, when Omni is enabled, up to 10 accounts per Organization | Eligibility is shown in the console when enabling. Not every account qualifies. |

## Worked example: seed-stage service

Two ECS Fargate tasks behind an ALB, 2,000 requests per minute at peak, one Region, production.

| Line | Assumption | Monthly |
|---|---|---|
| Application logs | 20 GB ingested, 30-day retention | $10.00 ingest + $0.09 storage |
| OTel metrics | 2 GB | $1.00 |
| Spans | 5 GB at 10 percent sampling | $1.75 |
| Alarms | 3 metric + 1 composite | $0.80 |
| Dashboard | 1 of the 3 free | $0 |
| Collector sidecar | 64 CPU units, 128 MB per task, 2 tasks | about $2 of Fargate |
| **CloudWatch total** | | **about $16** |
| Omni on top | 27 GB ingested gives a 135 GB scan allowance, and a two-person team scans far less | **$0** |
| Trial month | OTel ingestion covered by the $1,000 credit when eligible | **about $3** (alarms and the sidecar) |

Staging at a tenth of the traffic and 7-day retention fits inside the free tier except the sidecar.

## Worked example: Lambda service

One function behind a function URL, 500,000 invocations a month.

| Line | Assumption | Monthly |
|---|---|---|
| Function logs | 3 GB, 30-day retention | $1.50 |
| Spans from the ADOT layer | 1 GB at 10 percent sampling | $0.35 |
| Alarms | 3 metric + 1 composite | $0.80 |
| Dashboard | 1 of 3 free | $0 |
| **Total** | | **about $2.65**, most of it inside the free tier in a quiet month |

## Where the money goes wrong

| Trap | What it costs | Fix |
|---|---|---|
| `Never expire` on every log group | $0.03 per GB-month, compounding | Retention: 7 days staging, 30 production |
| Debug-level logging in production | Doubles or triples the ingestion line | Log level `INFO` in production, `DEBUG` in staging |
| 100 percent trace sampling | Ten times the span line | `OTEL_TRACES_SAMPLER_ARG=0.1` in production |
| Request ids as metric attributes | Every attribute is bytes on every data point, and a new series | Drop them at the collector or do not emit them |
| A dashboard per engineer | $3 each past the third | One per stage and Region |
| A third-party agent at seed stage | $15 to $50 per host per month plus per-GB logs, no credits | CloudWatch, and the `When to graduate` table in `architect-for-startups` |

## How to say it in DISCLOSE

One paragraph with their numbers: *"At your volume (N GB of logs, N GB of metrics, N GB of spans a
month) this costs about $X a month in CloudWatch, all of it covered by Activate credits, and Omni
adds nothing on top within the query allowance (and the first month's OpenTelemetry ingestion is
covered by the trial credit if your account is eligible). The thing to watch is log volume: the
retention I am proposing is 7 days in staging and 30 in production."*
