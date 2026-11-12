# One dashboard: the three alarms, the three symptom series, and recent errors
# from the OpenTelemetry log group when there is one. Nothing else until the
# service has been in production for three months and the team knows what fails.

locals {
  dims_list = local.is_alb ? ["LoadBalancer", var.alb_arn_suffix] : ["FunctionName", var.function_name]

  metric_widget = {
    error_rate = {
      title = "Error rate (%)"
      metrics = [
        concat([local.namespace, local.error_metric], local.dims_list, [{ id = "errors", visible = false, stat = "Sum" }]),
        concat([local.namespace, local.request_metric], local.dims_list, [{ id = "requests", visible = false, stat = "Sum" }]),
        [{ expression = "IF(requests > 0, 100 * errors / requests, 0)", label = "Error rate", id = "rate" }],
      ]
      annotations = { horizontal = [{ value = var.error_rate_percent, label = "alarm" }] }
    }
    latency = {
      title = "p99 latency (ms)"
      metrics = [
        concat([local.namespace, local.latency_metric], local.dims_list, [{ id = "latency", visible = false, stat = "p99" }]),
        [{ expression = local.latency_to_ms, label = "p99", id = "ms" }],
      ]
      annotations = { horizontal = [{ value = var.p99_latency_ms, label = "alarm" }] }
    }
    requests = {
      title = "Requests per minute"
      metrics = [
        concat([local.namespace, local.request_metric], local.dims_list, [{ stat = "Sum", label = "requests" }]),
      ]
      annotations = {}
    }
  }

  widgets = concat(
    [
      {
        type   = "alarm"
        x      = 0
        y      = 0
        width  = 24
        height = 3
        properties = {
          title = "${var.app_name} ${var.stage} ${var.region}"
          alarms = [
            aws_cloudwatch_metric_alarm.error_rate.arn,
            aws_cloudwatch_metric_alarm.p99_latency.arn,
            aws_cloudwatch_metric_alarm.saturation.arn,
          ]
        }
      },
    ],
    [
      for i, key in ["error_rate", "latency", "requests"] : {
        type   = "metric"
        x      = i * 8
        y      = 3
        width  = 8
        height = 6
        properties = merge(
          {
            title   = local.metric_widget[key].title
            region  = var.region
            view    = "timeSeries"
            stacked = false
            period  = 60
            metrics = local.metric_widget[key].metrics
          },
          length(local.metric_widget[key].annotations) > 0 ? { annotations = local.metric_widget[key].annotations } : {},
        )
      }
    ],
    var.otel_log_group == "" ? [] : [
      {
        type   = "log"
        x      = 0
        y      = 9
        width  = 24
        height = 6
        properties = {
          title  = "Recent errors (${var.otel_log_group})"
          region = var.region
          view   = "table"
          query  = "SOURCE '${var.otel_log_group}' | fields @timestamp, severity_text, body | filter severity_number >= 17 | sort @timestamp desc | limit 50"
        }
      },
    ],
  )
}

resource "aws_cloudwatch_dashboard" "this" {
  count          = var.create_dashboard ? 1 : 0
  dashboard_name = "${var.app_name}-${var.stage}-${var.region}"
  dashboard_body = jsonencode({ widgets = local.widgets })
}
