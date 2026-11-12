output "function_name" {
  value = aws_lambda_function.this.function_name
}

output "function_arn" {
  value = aws_lambda_function.this.arn
}

output "function_version" {
  value = aws_lambda_function.this.version
}

output "health_url" {
  description = "Read by deploy-stage.yml after apply and handed to the bake as the health URL."
  value       = aws_lambda_function_url.this.function_url
}

output "log_group" {
  value = aws_cloudwatch_log_group.function.name
}
