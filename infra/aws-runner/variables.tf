variable "aws_profile" {
  description = "Local AWS CLI profile used to deploy the runner control plane."
  type        = string
  default     = "seapath"
}

variable "enable_cache_storage" {
  description = "Delete the temporary S3 cache after recovering evaluation results."
  type        = bool
  default     = true
}

variable "aws_region" {
  description = "Region for the initial SEAPATH runner evaluation."
  type        = string
  default     = "eu-west-3"

  validation {
    condition     = var.aws_region == "eu-west-3"
    error_message = "This evaluation is scoped to eu-west-3 (Paris)."
  }
}

variable "prefix" {
  description = "Unique name prefix for this runner deployment."
  type        = string
  default     = "seapath-yocto-ci"
}

variable "github_repository" {
  description = "Only repository allowed to start runners."
  type        = string
  default     = "dupremathieu/yocto-bsp"
}

variable "ami_id" {
  description = "Canonical Ubuntu 24.04 amd64 image validated in Paris."
  type        = string
  default     = "ami-001b955040bc46321"
}

variable "github_app_ssm_path" {
  description = "Externally managed SSM SecureStrings; secret values never enter Terraform."
  type        = string
  default     = "/seapath/ec2-runner/github-app"
}
