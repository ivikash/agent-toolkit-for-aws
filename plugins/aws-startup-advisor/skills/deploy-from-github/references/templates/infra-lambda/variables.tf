# The pipeline contract (region, image_tag, image_uri, artifact_path) plus this
# root's own settings. Stage settings live in env/<stage>.tfvars.

variable "region" {
  description = "Region this apply targets. Supplied by the workflow as TF_VAR_region."
  type        = string
}

variable "image_tag" {
  description = "Commit SHA of the deployed version. Supplied by the workflow as TF_VAR_image_tag."
  type        = string
  default     = ""
}

variable "image_uri" {
  description = "Container image URI. Not used by this root, declared for the contract."
  type        = string
  default     = ""
}

variable "artifact_path" {
  description = "Local path to function.zip. Supplied by the workflow as TF_VAR_artifact_path."
  type        = string
}

variable "app_name" {
  description = "Application name. Must match the bootstrap's app_name."
  type        = string
}

variable "stage" {
  description = "staging or production."
  type        = string
}

variable "handler" {
  description = "Function handler, e.g. app.handler."
  type        = string
}

variable "runtime" {
  description = "Lambda runtime identifier, e.g. python3.13 or nodejs22.x."
  type        = string
}

variable "architecture" {
  description = "x86_64 or arm64. Must match how build.sh built the zip's dependencies."
  type        = string
  default     = "x86_64"
}

variable "memory_mb" {
  type    = number
  default = 512
}

variable "timeout_seconds" {
  type    = number
  default = 30
}

variable "environment" {
  description = "Extra environment variables for the function."
  type        = map(string)
  default     = {}
}

variable "log_retention_days" {
  description = "7 in staging, 30 in production is the usual startup setting."
  type        = number
}

variable "tracing" {
  description = "Enable X-Ray active tracing on the function."
  type        = bool
  default     = false
}

variable "function_url_auth" {
  description = "NONE for a public URL (the health check needs to reach it), AWS_IAM otherwise."
  type        = string
  default     = "NONE"

  validation {
    condition     = contains(["NONE", "AWS_IAM"], var.function_url_auth)
    error_message = "function_url_auth must be NONE or AWS_IAM."
  }
}
