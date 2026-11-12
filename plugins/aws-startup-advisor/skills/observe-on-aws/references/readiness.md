# Readiness: what exists, and what the service's own numbers say

Every command is read-only. Run them in order, record each answer, and route on the table at
the end. Replace `<app>`, `<stage>` and `<region>` with the user's values.

## 1. Runtime and language

From the repository: `Dockerfile` and a task definition or `aws_ecs_*` Terraform mean ECS.
`template.yaml`, `aws_lambda_function`, or a handler file mean Lambda. `kind: Deployment` or
`aws_eks_*` mean EKS. `aws_instance` or UserData mean EC2. `pyproject.toml` or `requirements.txt`
is Python, `package.json` is Node.js, `pom.xml` or `build.gradle` is Java, `*.csproj` is .NET.

From the account, when signed in:

```sh
aws ecs list-clusters --query 'clusterArns' --output text
aws ecs describe-services --cluster <app>-<stage> --services <app>-<stage> \
  --query 'services[0].{taskDef:taskDefinition,lb:loadBalancers[0].targetGroupArn}'
aws lambda get-function-configuration --function-name <app>-<stage> \
  --query '{runtime:Runtime,layers:Layers[].Arn,env:Environment.Variables,tracing:TracingConfig.Mode}'
```

## 2. Existing instrumentation and destination

```sh
grep -rliE "opentelemetry|aws-otel|aws_xray_sdk|aws-xray-sdk|ddtrace|newrelic" --include='*.txt' --include='*.toml' --include='*.json' --include='*.xml' --include='*.gradle' --include='*.csproj' . 2>/dev/null | head
aws ecs describe-task-definition --task-definition <taskDef> \
  --query 'taskDefinition.containerDefinitions[].{name:name,image:image,env:environment[?starts_with(name, `OTEL_`)].name}'
```

| Finding | Meaning |
|---|---|
| `OTEL_*` variables on the application container, an `opentelemetry` dependency | The SDK is already in. INSTRUMENT shrinks to the destination and the resource attributes. |
| A `cloudwatch-agent` or `aws-otel-collector` container, or `OTEL_EXPORTER_OTLP_ENDPOINT` set | A destination exists. Do not add a second collector. Confirm it listens on 4317 or 4318 (an agent configured only for Application Signals listens on 4316 and is not an OTLP destination for this path). |
| `OTEL_AWS_APPLICATION_SIGNALS_ENABLED=true` | Application Signals is on. Keep it. The plain-ADOT collector must not be added beside it. |
| `aws_xray_sdk` or `aws-xray-sdk` | X-Ray SDK, maintenance mode. OpenTelemetry is the replacement, and this skill's INSTRUMENT is the migration. |
| `ddtrace`, `newrelic`, `dd-agent` | A third-party agent, priced per host. Name the cost before proposing anything. |
| Nothing | Instrumentation from scratch. |

## 3. Log groups and retention

```sh
aws logs describe-log-groups --log-group-name-prefix /ecs/<app> \
  --query 'logGroups[].{name:logGroupName,retentionDays:retentionInDays,storedBytes:storedBytes}' --output table
aws logs describe-log-groups --log-group-name-prefix /aws/lambda/<app> \
  --query 'logGroups[].{name:logGroupName,retentionDays:retentionInDays,storedBytes:storedBytes}' --output table
```

A missing `retentionDays` is `Never expire`. `storedBytes` divided by the group's age gives the
daily ingestion the cost estimate needs. Note every group, with its current retention, before
proposing a change: lowering retention deletes data, and the user agrees to that per group.

## 4. Alarms and dashboards

```sh
aws cloudwatch describe-alarms --alarm-name-prefix <app>-<stage>-<region>- \
  --query 'MetricAlarms[].{name:AlarmName,state:StateValue,threshold:Threshold,actions:AlarmActions}' --output table
aws cloudwatch describe-alarms --query "MetricAlarms[?contains(AlarmName, '<app>')].AlarmName" --output text
aws cloudwatch list-dashboards --query "DashboardEntries[?contains(DashboardName, '<app>')].DashboardName" --output text
```

Alarms with the full prefix are a previous run of this skill. Alarms that merely contain the app
name were built by hand: read them (`describe-alarms --alarm-names`) and say which of the minimum
set they already cover.

## 5. Omni

```sh
aws cloudwatchomni list-domains --region <region>
aws cloudwatchomni list-spaces --region <region> --query "items[?region=='<region>']"
```

`list-spaces` is account-global: the `--region` flag picks the endpoint, and the response lists
every Space in the account with its own `region`. Filter, do not trust a non-empty list. A Space in
this Region means the Omni path is already open. A Domain and no Space in this Region means one
`create-space` away. Neither means the full setup in `omni.md`. An `AccessDenied` or an unknown
command means the caller cannot see Omni, not that Omni is absent: say so.

## 6. Grounding the thresholds

Two weeks of the service's own numbers, one call each. State the unit when writing them down.

```sh
START=$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-14d +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ALB: 5xx, requests, p99 latency (seconds), unhealthy hosts
aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB --metric-name HTTPCode_Target_5XX_Count \
  --dimensions Name=LoadBalancer,Value=<alb-arn-suffix> --start-time "$START" --end-time "$END" --period 3600 --statistics Sum
aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB --metric-name RequestCount \
  --dimensions Name=LoadBalancer,Value=<alb-arn-suffix> --start-time "$START" --end-time "$END" --period 3600 --statistics Sum
aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB --metric-name TargetResponseTime \
  --dimensions Name=LoadBalancer,Value=<alb-arn-suffix> --start-time "$START" --end-time "$END" --period 3600 --extended-statistics p99

# Lambda: errors, invocations, p99 duration (milliseconds), throttles
aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Errors \
  --dimensions Name=FunctionName,Value=<app>-<stage> --start-time "$START" --end-time "$END" --period 3600 --statistics Sum
aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Invocations \
  --dimensions Name=FunctionName,Value=<app>-<stage> --start-time "$START" --end-time "$END" --period 3600 --statistics Sum
aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Duration \
  --dimensions Name=FunctionName,Value=<app>-<stage> --start-time "$START" --end-time "$END" --period 3600 --extended-statistics p99
```

Compute the hourly error rate (`errors / requests * 100`) and take its typical and peak values,
and the peak hourly p99. `minimum-set.md`, "Grounding a threshold", turns them into a proposal. An
empty response is "no history", not zero: say so, and ask the user for the numbers.

## Routing

| Result | Do |
|---|---|
| SDK and destination present, alarms absent | ASSESS, then WATCH. Skip INSTRUMENT. |
| Alarms with the full prefix present | A previous run. Compare thresholds with ASSESS, propose changes, create nothing. |
| Application Signals on | Keep it. Alarms and dashboard still apply. Route any Application Signals change to `setting-up-cloudwatch-observability`. |
| No AWS sign-in | DETECT from the repository only, ASSESS is "no history", DISCLOSE with the user's volume estimate, and stop before INSTRUMENT until they sign in. |
| Nothing | Continue. |
