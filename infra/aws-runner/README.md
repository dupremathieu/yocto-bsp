# Yocto EC2 runner evaluation

This is a separate Terraform deployment from the virtual-cluster runner. It uses
the same owned GitHub App and external SSM credential references, but separate
IAM roles, queues, webhook and launch template. It accepts only
`dupremathieu/yocto-bsp` and labels `[self-hosted, linux, x64, seapath-ec2-yocto]`.

- Paris (`eu-west-3`), Canonical Ubuntu 24.04, On-Demand `m7i.2xlarge`: 8 vCPU,
  32 GiB RAM. Nested virtualization is not enabled for Yocto.
- Encrypted 300 GiB gp3 root disk, deleted when the runner terminates.
- One job per instance, no idle pool, up to four instances for independent image
  workflows. The first evaluation launches **only host_efi**. Four simultaneous
  instances require 32 vCPU of regional EC2 Standard On-Demand quota; the current
  quota is 8. A request for 32 was submitted on 2026-10-19 and is pending.
- Docker, CQFD 5.10.2 (SHA-256 verified), Google repo and AWS CLI at bootstrap.
- Nine-hour GitHub job timeout, ten-hour independent instance shutdown timer.
  The runner's exit handler terminates the instance after its single job.
- No inbound network access. Minimum ten-minute boot protection. No Lambda
  reserved concurrency, as in the virtual-cluster deployment.
- A private, encrypted S3 cache bucket; cache objects expire after seven days.
  The instance role can read and write only this cache bucket in addition to
  the upstream runner lifecycle permissions. Tar streams preserve cache file
  modes and links, without storing a second archive on the runner's disk.

See [the evaluation protocol](../../docs/yocto-ec2-evaluation.md).

## Deploy

Run from this directory with Terraform, authenticated AWS profile `seapath`,
GitHub CLI, Python and OpenSSL. Install the owned GitHub App on the Yocto fork.
Keep its PEM outside Git. The existing virtual-cluster deployment's ignored PEM
can be reused without copying it into this repository.

```sh
python3 download-lambdas.py
terraform init
terraform fmt -check
terraform validate
python3 configure-github-app.py --app-id 5370432 --private-key /absolute/private/key.pem \
  --repository dupremathieu/yocto-bsp
terraform plan -out=yocto.tfplan
terraform apply yocto.tfplan
python3 configure-github-app.py --app-id 5370432 --private-key /absolute/private/key.pem \
  --repository dupremathieu/yocto-bsp \
  --webhook-url "$(terraform output -raw webhook_endpoint)"
gh variable set YOCTO_EC2_CACHE_BUCKET --repo dupremathieu/yocto-bsp \
  --body "$(terraform output -raw cache_bucket)"
```

The first run starts with empty caches and populates them on AWS. The workflow
then removes the ephemeral build directory and performs its reference build with
the resulting download and sstate caches. Subsequent runs restore only a cache
published by a successful AWS reference run. Do not seed this deployment from
the development machine's invalid `build/` caches.

Lambda assets are pinned to module v7.11.0 and verified against release hashes.
The module and helpers originate from the tested virtual-cluster deployment.
Terraform state, plans, Lambda ZIPs and `.local/` are ignored. Keep the state to
remove this deployment later. Secret values remain outside Terraform state.

## Teardown

Stop running builds and disable this repository's webhook before `terraform
destroy`. Check that dynamically launched instances have terminated: Terraform
does not track them individually. `force_destroy` removes this evaluation's
cache objects with its S3 bucket. Shared external GitHub App credentials in SSM
are not removed; do not delete them while the virtual-cluster runner uses them.

References: [runner configuration](https://github-aws-runners.github.io/terraform-aws-github-runner/configuration/),
[module v7.11.0](https://github.com/github-aws-runners/terraform-aws-github-runner/releases/tag/v7.11.0).
