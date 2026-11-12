# Offline tests: names the deploy bake relies on, units, and the one-page rule.
#   terraform -chdir=<module> test

mock_provider "aws" {}

variables {
  app_name           = "example"
  stage              = "production"
  region             = "us-west-2"
  error_rate_percent = 2
  p99_latency_ms     = 1500
}

run "alb_names_units_and_paging" {
  command = plan

  variables {
    compute                 = "alb"
    alb_arn_suffix          = "app/example-production/0123456789abcdef"
    target_group_arn_suffix = "targetgroup/example-production/fedcba9876543210"
    alert_email             = "oncall@example.com"
    otel_log_group          = "/ecs/example-production/app"
  }

  assert {
    condition = toset(output.alarm_names) == toset([
      "example-production-us-west-2-error-rate",
      "example-production-us-west-2-p99-latency",
      "example-production-us-west-2-unhealthy-hosts",
    ])
    error_message = "alarm names must be <app>-<stage>-<region>-<signal>"
  }
  assert {
    condition     = output.alarm_name_prefix == "example-production-us-west-2-"
    error_message = "prefix must match what the deploy bake watches"
  }
  assert {
    condition     = [for q in aws_cloudwatch_metric_alarm.p99_latency.metric_query : q.expression if q.id == "latency_ms"][0] == "latency * 1000"
    error_message = "ALB TargetResponseTime is seconds and must be converted to milliseconds before the comparison"
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.p99_latency.threshold == 1500
    error_message = "the latency threshold is compared in milliseconds"
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.saturation.metric_name == "UnHealthyHostCount" && aws_cloudwatch_metric_alarm.saturation.statistic == "Maximum"
    error_message = "alb saturation watches UnHealthyHostCount"
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.error_rate.alarm_actions == null && length(aws_cloudwatch_composite_alarm.health.alarm_actions) == 1
    error_message = "only the composite alarm pages"
  }
  assert {
    condition     = length(aws_sns_topic_subscription.email) == 1
    error_message = "an alert email creates one subscription"
  }
  assert {
    condition     = length(aws_cloudwatch_dashboard.this) == 1 && length(local.widgets) == 5
    error_message = "with a log group the dashboard has the alarm strip, three series, and the errors panel"
  }
}

run "lambda_names_and_units" {
  command = plan

  variables {
    compute       = "lambda"
    function_name = "example-production"
  }

  assert {
    condition     = contains(output.alarm_names, "example-production-us-west-2-throttles")
    error_message = "lambda saturation is throttles"
  }
  assert {
    condition     = [for q in aws_cloudwatch_metric_alarm.p99_latency.metric_query : q.expression if q.id == "latency_ms"][0] == "latency"
    error_message = "Lambda Duration is already milliseconds"
  }
  assert {
    condition     = contains([for q in aws_cloudwatch_metric_alarm.error_rate.metric_query : try(q.metric[0].metric_name, "")], "Errors")
    error_message = "lambda error rate divides Errors by Invocations"
  }
  assert {
    condition     = length(aws_sns_topic_subscription.email) == 0 && length(local.widgets) == 4
    error_message = "no email means no subscription, no log group means no errors panel"
  }
}

run "no_dashboard" {
  command = plan

  variables {
    compute          = "lambda"
    function_name    = "example-production"
    create_dashboard = false
  }

  assert {
    condition     = length(aws_cloudwatch_dashboard.this) == 0 && output.dashboard_name == ""
    error_message = "create_dashboard = false creates no dashboard"
  }
}
