variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-southeast-1"
}

variable "aws_account_id" {
  description = "AWS account ID (used for globally unique S3 bucket names)"
  type        = string
}

variable "project" {
  description = "Project name prefix for all resource names"
  type        = string
  default     = "contoso"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod."
  }
}

variable "acm_certificate_arn" {
  description = "ARN of ACM certificate for ALB HTTPS listener"
  type        = string
  sensitive   = false
}
