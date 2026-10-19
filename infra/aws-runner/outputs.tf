output "webhook_endpoint" {
  description = "Repository webhook URL; configure with the external webhook secret."
  value       = module.github_runner.webhook.endpoint
}

output "runner_launch_template_id" {
  value = module.github_runner.runners.launch_template_id
}

output "runner_labels" {
  value = module.github_runner.runners.labels
}

output "github_app_ssm_parameters" {
  description = "Parameter names only; values are maintained outside Terraform."
  value       = local.secret_names
}

output "cache_bucket" {
  value = aws_s3_bucket.yocto_cache.id
}
