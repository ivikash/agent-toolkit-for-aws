locals {
  prefix = "${var.app_name}-${var.stage}-${var.region}-"
  is_alb = var.compute == "alb"

  # Symptom metrics per compute. Units matter: ALB TargetResponseTime is seconds,
  # Lambda Duration is milliseconds. Both alarms compare in milliseconds, so the
  # ALB latency is multiplied by 1000 in metric math before the comparison.
  namespace = local.is_alb ? "AWS/ApplicationELB" : "AWS/Lambda"
  dimensions = local.is_alb ? {
    LoadBalancer = var.alb_arn_suffix
    } : {
    FunctionName = var.function_name
  }
  error_metric    = local.is_alb ? "HTTPCode_Target_5XX_Count" : "Errors"
  request_metric  = local.is_alb ? "RequestCount" : "Invocations"
  latency_metric  = local.is_alb ? "TargetResponseTime" : "Duration"
  latency_to_ms   = local.is_alb ? "latency * 1000" : "latency"
  saturation_name = local.is_alb ? "unhealthy-hosts" : "throttles"

  tags = {
    app        = var.app_name
    stage      = var.stage
    managed-by = "observe-on-aws"
  }
}

# ---- where a page goes ---------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${var.app_name}-${var.stage}-alerts"
  tags = local.tags
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---- 1. error rate ----------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "error_rate" {
  alarm_name          = "${local.prefix}error-rate"
  alarm_description   = "${var.compute == "alb" ? "5xx responses" : "function errors"} above ${var.error_rate_percent}% of requests for ${var.datapoints_to_alarm} of ${var.evaluation_periods} minutes"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.error_rate_percent
  evaluation_periods  = var.evaluation_periods
  datapoints_to_alarm = var.datapoints_to_alarm
  treat_missing_data  = "notBreaching"
  tags                = local.tags

  metric_query {
    id          = "errors"
    return_data = false
    metric {
      namespace   = local.namespace
      metric_name = local.error_metric
      period      = 60
      stat        = "Sum"
      dimensions  = local.dimensions
    }
  }

  metric_query {
    id          = "requests"
    return_data = false
    metric {
      namespace   = local.namespace
      metric_name = local.request_metric
      period      = 60
      stat        = "Sum"
      dimensions  = local.dimensions
    }
  }

  metric_query {
    id          = "error_rate"
    label       = "Error rate (%)"
    expression  = "IF(requests > 0, 100 * errors / requests, 0)"
    return_data = true
  }
}

# ---- 2. p99 latency -------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "p99_latency" {
  alarm_name          = "${local.prefix}p99-latency"
  alarm_description   = "p99 latency above ${var.p99_latency_ms} ms for ${var.datapoints_to_alarm} of ${var.evaluation_periods} minutes"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.p99_latency_ms
  evaluation_periods  = var.evaluation_periods
  datapoints_to_alarm = var.datapoints_to_alarm
  treat_missing_data  = "notBreaching"
  tags                = local.tags

  metric_query {
    id          = "latency"
    return_data = false
    metric {
      namespace   = local.namespace
      metric_name = local.latency_metric
      period      = 60
      stat        = "p99"
      dimensions  = local.dimensions
    }
  }

  metric_query {
    id          = "latency_ms"
    label       = "p99 latency (ms)"
    expression  = local.latency_to_ms
    return_data = true
  }
}

# ---- 3. saturation: unhealthy targets, or throttled invocations --------------------------------

resource "aws_cloudwatch_metric_alarm" "saturation" {
  alarm_name          = "${local.prefix}${local.saturation_name}"
  alarm_description   = local.is_alb ? "at least one target failing its health check" : "at least one invocation throttled"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = var.evaluation_periods
  datapoints_to_alarm = var.datapoints_to_alarm
  treat_missing_data  = "notBreaching"
  namespace           = local.namespace
  metric_name         = local.is_alb ? "UnHealthyHostCount" : "Throttles"
  statistic           = local.is_alb ? "Maximum" : "Sum"
  period              = 60
  tags                = local.tags

  dimensions = local.is_alb ? {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  } : local.dimensions
}

# ---- one page --------------------------------------------------------------------------
# The three alarms carry the signal and the deploy bake reads them. Only the
# composite notifies, so one incident is one page, not three.

resource "aws_cloudwatch_composite_alarm" "health" {
  alarm_name        = "${local.prefix}health"
  alarm_description = "${var.app_name} ${var.stage} in ${var.region}: error rate, p99 latency, or ${local.saturation_name}"
  alarm_rule = join(" OR ", [
    "ALARM(${aws_cloudwatch_metric_alarm.error_rate.alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.p99_latency.alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.saturation.alarm_name})",
  ])
  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
  tags          = local.tags
}
