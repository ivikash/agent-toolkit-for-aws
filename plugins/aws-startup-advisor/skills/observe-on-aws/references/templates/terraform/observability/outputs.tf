output "alarm_names" {
  description = "The three metric alarms. The deploy bake watches alarms with this prefix."
  value = [
    aws_cloudwatch_metric_alarm.error_rate.alarm_name,
    aws_cloudwatch_metric_alarm.p99_latency.alarm_name,
    aws_cloudwatch_metric_alarm.saturation.alarm_name,
  ]
}

output "alarm_name_prefix" {
  description = "<app>-<stage>-<region>-, the prefix every alarm here carries."
  value       = local.prefix
}

output "composite_alarm_name" {
  description = "The one alarm that pages."
  value       = aws_cloudwatch_composite_alarm.health.alarm_name
}

output "sns_topic_arn" {
  description = "Where the page goes. Subscribe Slack, a pager, or more addresses here."
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_name" {
  description = "The one dashboard. Empty when create_dashboard is false."
  value       = var.create_dashboard ? aws_cloudwatch_dashboard.this[0].dashboard_name : ""
}
