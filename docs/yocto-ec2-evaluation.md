# Yocto CI evaluation on EC2

The existing Savoir-faire Linux CI is unchanged. The evaluation adds one manual
workflow per image: `build-ec2-host-efi.yml`, `build-ec2-host-standalone-efi.yml`,
`build-ec2-guest-efi.yml` and `build-ec2-observer-efi.yml`. They call the reusable
`_build-ec2.yml`. Each image gets its own ephemeral 8-vCPU EC2 instance; workflows
for different images can run concurrently when the regional quota permits.
Concurrency is serialized only within the same image, protecting its cache
pointer. **The initial test builds only host_efi.**

GitHub requires manual workflows to exist on the default branch before dispatch.
The initial fork-branch test uses a narrowly scoped temporary push trigger;
remove it after launch. No release files are uploaded to the production R2 bucket.

## Cache and reference build

The reference is a build with populated caches, not an incremental rebuild using
an existing `tmp/` directory or BitBake task stamps:

1. Sync `wrynose.xml`, then fetch the exact workflow commit from the Yocto fork.
   Record the resolved manifest and meta-seapath revision in the results.
2. Restore downloads and sstate from the last successful per-image S3 cache.
   On the first run, restore the development machine's populated seed caches
   (about 20 GiB downloads and 19 GiB sstate at preparation time).
3. Build the selected image once to complete/populate the caches for these exact
   sources. This phase is **not described as a cold build**: the seed may provide
   many cache hits. Its duration is recorded separately.
4. Remove only the ephemeral workspace's `build/` directory. Keep downloads and
   sstate in separate mounts. Rebuild the same image and time this **reference**.
5. Record image sizes/digests, SBOM, stage times, cache sizes, `/usr/bin/time`
   output, instance identity, memory and disk snapshots. BitBake's log records
   the sstate summary and task counts, allowing cache hits to be inspected.
6. Stream the updated caches into an immutable per-run, per-image S3 prefix;
   publish `latest.json` only after the reference and both uploads succeed.
   Preserve logs and metadata as GitHub artifacts even when a build fails.

The measured reference excludes source sync, cache restore, Docker initialization
and cache publication; all these stages are timed separately and **must be added
for the full CI runtime and EC2 cost**. Both builds use the same sources, Docker
image and instance. An independent-instance comparison of storage/OS page-cache
effects remains a separate experiment. S3 archives provide reproducibility and
preserve modes/links, but upload the whole cache: transfer duration and S3 storage
are part of the evaluation, and may justify a different caching method later.

CQFD cache mounts and parallelism are explicit; the workflow does not source a
runner administrator's bashrc. Four BitBake tasks and four make workers per task
are allowed, with the Ceph make limit set to four for the initial 32-GiB machine.
`SEAPATH_SECCOMPILE_MANIFEST_SKIP=1` and the sample's `SEAPATH_RM_WORK=true` remain
enabled. The public Ansible key is empty as in the existing CI; the images are
test artifacts, not deployment images with an authorized SSH key.

## Cost basis

AWS Price List API checked on 2026-10-19: Paris `m7i.2xlarge` Linux On-Demand
is USD 0.4704/hour (SKU D26FR8DKJBSZ8AX6), and gp3 storage is USD 0.0928/GiB-month
(SKU XCKADFE99D2BK5V6). With a 300-GiB disk and public IPv4 at USD 0.005/hour,
the direct rate is approximately **USD 0.513/hour** using October's 744 hours.
Multiply by total instance lifetime, including both builds and cache transfers.
This excludes S3 cache storage/requests, controller services, data transfers,
GitHub artifact storage and taxes, before credits. It is not a bill or a measured
build estimate. The controller and S3 cache remain after the EC2 runner exits.

Sources: [EC2 pricing](https://aws.amazon.com/ec2/pricing/on-demand/),
[EBS pricing](https://aws.amazon.com/ebs/pricing/),
[IPv4 pricing](https://aws.amazon.com/vpc/pricing/).
