variable "app_name" {
  description = "Application name. First segment of every alarm and dashboard name."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.app_name))
    error_message = "app_name must be lowercase letters, digits and hyphens, 2 to 31 characters, starting with a letter."
  }
}

variable "stage" {
  description = "staging or production."
  type        = string

  validation {
    condition     = contains(["staging", "production"], var.stage)
    error_message = "stage must be staging or production."
  }
}

variable "region" {
  description = "Region the alarms live in. Part of the alarm names so the deploy bake can find them per Region."
  type        = string
}

variable "compute" {
  description = "Where the request metrics come from: alb (an Application Load Balancer in front of ECS or EC2) or lambda (a function behind a function URL or API Gateway)."
  type        = string

  validation {
    condition     = contains(["alb", "lambda"], var.compute)
    error_message = "compute must be alb or lambda."
  }
}

variable "alb_arn_suffix" {
  description = "alb only: the LoadBalancer dimension, app/<name>/<id> (aws_lb.this.arn_suffix)."
  type        = string
  default     = ""

  validation {
    condition     = var.compute != "alb" || var.alb_arn_suffix != ""
    error_message = "alb_arn_suffix is required when compute is alb."
  }
}

variable "target_group_arn_suffix" {
  description = "alb only: the TargetGroup dimension, targetgroup/<name>/<id> (aws_lb_target_group.this.arn_suffix)."
  type        = string
  default     = ""

  validation {
    condition     = var.compute != "alb" || var.target_group_arn_suffix != ""
    error_message = "target_group_arn_suffix is required when compute is alb."
  }
}

variable "function_name" {
  description = "lambda only: the function name."
  type        = string
  default     = ""

  validation {
    condition     = var.compute != "lambda" || var.function_name != ""
    error_message = "function_name is required when compute is lambda."
  }
}

# Thresholds have no defaults on purpose. A guessed threshold fires never or
# always, and the user cannot tell which. references/minimum-set.md explains how
# to ground them in two weeks of the service's own data before setting them.
variable "error_rate_percent" {
  description = "Alarm when 5xx (alb) or errors (lambda) exceed this percentage of requests. Grounded in the service's own history, never guessed."
  type        = number

  validation {
    condition     = var.error_rate_percent > 0 && var.error_rate_percent <= 100
    error_message = "error_rate_percent must be between 0 and 100."
  }
}

variable "p99_latency_ms" {
  description = "Alarm when p99 latency exceeds this many milliseconds. Grounded in the service's own history, never guessed."
  type        = number

  validation {
    condition     = var.p99_latency_ms > 0
    error_message = "p99_latency_ms must be positive."
  }
}

variable "evaluation_periods" {
  description = "Number of one-minute periods evaluated. The alarm fires when datapoints_to_alarm of them breach."
  type        = number
  default     = 3
}

variable "datapoints_to_alarm" {
  description = "Breaching periods out of evaluation_periods needed to fire. 2 of 3 ignores a single bad minute."
  type        = number
  default     = 2
}

variable "alert_email" {
  description = "Address the composite alarm pages. Empty means a topic with no subscription, for the user to wire to Slack or a pager later."
  type        = string
  default     = ""
}

variable "otel_log_group" {
  description = "Optional. Log group holding the application's OpenTelemetry logs; adds a recent-errors panel to the dashboard."
  type        = string
  default     = ""
}

variable "create_dashboard" {
  description = "Create the one dashboard. The first three dashboards in an account are free."
  type        = bool
  default     = true
}
