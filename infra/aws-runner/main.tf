data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

locals {
  secret_names = {
    id             = "${var.github_app_ssm_path}/id"
    key_base64     = "${var.github_app_ssm_path}/key-base64"
    webhook_secret = "${var.github_app_ssm_path}/webhook-secret"
  }
  secret_refs = {
    for key, name in local.secret_names : key => {
      name = name
      arn  = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${name}"
    }
  }
}

module "github_runner" {
  source  = "github-aws-runners/github-runner/aws"
  version = "7.11.0"

  prefix     = var.prefix
  aws_region = var.aws_region
  vpc_id     = data.aws_vpc.default.id
  subnet_ids = sort(data.aws_subnets.default.ids)

  github_app = {
    id_ssm             = local.secret_refs.id
    key_base64_ssm     = local.secret_refs.key_base64
    webhook_secret_ssm = local.secret_refs.webhook_secret
  }

  enable_organization_runners = false
  repository_white_list       = [var.github_repository]
  runner_extra_labels         = ["seapath-ec2-yocto"]
  runner_name_prefix          = "seapath-yocto-"
  enable_dynamic_labels       = false

  instance_types                = ["m7i.2xlarge"]
  instance_target_capacity_type = "on-demand"
  runners_maximum_count         = 4
  enable_ephemeral_runners      = true
  enable_job_queued_check       = true
  delay_webhook_event           = 0
  runner_boot_time_in_minutes   = 10
  # JIT runners are registered before boot and initially appear idle to GitHub.
  # Protect them from scale-down until Ubuntu and the runner have started.
  minimum_running_time_in_minutes = 10
  scale_down_schedule_expression  = "cron(* * * * ? *)"

  # The account currently has only five concurrent Lambda executions.
  # Reserving any concurrency would require at least 100 unreserved executions.
  scale_up_reserved_concurrent_executions = -1
  eventbridge = {
    enable = false
  }

  runner_os                     = "linux"
  runner_architecture           = "x64"
  runner_run_as                 = "ubuntu"
  associate_public_ipv4_address = true
  enable_ssm_on_runners         = false
  userdata_template             = "${path.module}/ubuntu-user-data.sh.tftpl"

  ami = {
    owners = ["099720109477"]
    filter = {
      name         = ["*"]
      image-id     = [var.ami_id]
      state        = ["available"]
      architecture = ["x86_64"]
    }
  }
  block_device_mappings = [{
    device_name           = "/dev/sda1"
    volume_size           = 300
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }]

  enable_cloudwatch_agent           = false
  logging_retention_in_days         = 7
  create_service_linked_role_spot   = false
  webhook_lambda_zip                = "${path.module}/.artifacts/webhook.zip"
  runners_lambda_zip                = "${path.module}/.artifacts/runners.zip"
  runner_binaries_syncer_lambda_zip = "${path.module}/.artifacts/runner-binaries-syncer.zip"
}
