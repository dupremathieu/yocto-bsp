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

1. Sync the fork's `wrynose-ec2.xml` at tag `yocto-ec2-2026-10-19-v2`.
   Every project, including the BSP, is pinned to a full commit SHA. The workflow
   driver is loaded from a separate checkout; it does not replace the pinned BSP.
   Record the resolved manifest and meta-seapath revision in the results.
2. Restore downloads and sstate from the last successful per-image S3 cache.
   On the first run, start empty and populate the cache on AWS. The development
   machine's caches were identified as invalid by the user; the initial uploaded
   copies were deleted, and there is no local-seed fallback in the workflow.
3. Build the selected image once to complete/populate the caches for these exact
   sources. The initial run is a cold build; subsequent runs may restore a
   previously verified AWS cache. Its duration is recorded separately.
4. Remove only the ephemeral workspace's `build/` directory. Keep downloads and
   sstate in separate mounts. Rebuild the same image and time this **reference**.
5. Record image sizes/digests, SBOM, stage times, cache sizes, `/usr/bin/time`
   output, instance identity, and sampled Docker CPU/memory plus host disk and
   memory usage. Host `/usr/bin/time` does not measure container peak RSS.
   BitBake's log records
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

## Initial run — 2026-10-19

[host_efi evaluation run](https://github.com/dupremathieu/yocto-bsp/actions/runs/39306923690)
started from commit `647e0555f92e5806cef5c618afdb870445743bb5`. Instance
`i-0a259ef8f580da0fd` launched at 18:57:49 UTC; the job started at 18:58:54 UTC.
Bootstrap, checkout and runner configuration checks passed. The run was then
cancelled to prepare the local source/cache baseline first; the instance is
terminated and its root volume was removed. No completed-build result,
cache-hit rate or measured cost is claimed. The initial S3 cache bucket was
empty at launch.

The four image workflows are manual-only after this launch. GitHub Actions had
to be enabled on the fork before it would process push events. The initial
temporary branch trigger has been removed.

## Local source alignment — 2026-10-19

The local workspace now selects `wrynose.xml` from the official
`https://github.com/seapath/repo-manifest.git`, branch `main`, commit
`2ee72789c96e43f0cb534c1e61913ac049b68804`. Its Git blob
`76d6b6f81e23b8a27749d3afea0055f66475df43` was verified against GitHub.
All 13 repositories under `sources/` match the manifest's resolved revisions;
six changed. Existing local patches in meta-cgl and meta-secure-core were
restored identically after synchronization. Existing source branches remain
available; working trees are detached at the manifest revisions.

The BSP's CI branch, configuration, keys and local caches were preserved. No
`cqfd -b host_efi` was launched. Before/after revision manifests and patch backups
are under `.repo/local-backups/2026-10-19-before-wrynose-sync/` locally. Await the
user's instruction before building or transferring any local cache again.

## Pinned fork and local-cache reference

The subsequent local build in container `67ebe94cdff1` exited with code 1 on
2026-10-19. LXC source fetching failed. It was an optional build dependency of
libvirt; the forked meta-seapath disables its unused `lxc` PACKAGECONFIG option.
BitBake graph generation for host_efi passed and confirmed that lxc is absent
while libvirt and QEMU remain. A complete image build still has to succeed.

The new evaluation manifest is `wrynose-ec2.xml` in
`https://github.com/dupremathieu/repo-manifest.git`, selected with
`-b refs/tags/yocto-ec2-2026-10-19-v1`. Each project uses a full SHA, with the BSP
and corrected meta-seapath taken from the user's forks. The tag identifies this
candidate baseline; it is not a claim that the full image build has passed.

After a successful local build, `tools/ci/publish-local-cache.py` checks its
recorded exit code, image, configuration, source revisions and patch hashes
before streaming caches to S3. The host workflow's `cache_prefix` input selects
this verified snapshot. In this mode it restores the source lock and local
configuration, builds host_efi once from a fresh build directory, and does not
perform another populate build or upload the caches again.

The user authorized a 15-minute thread follow-up, upload after local success,
the AWS reference, and cache storage deletion after results recovery. Local
failure never authorizes using that failed attempt as a successful cache seed.
After the evaluation, set `enable_cache_storage=false` and review/apply Terraform
to delete only the five cache resources; retain local caches and result files.

## Second baseline: omit setup-ovs for the compilation evaluation

The first retry, container `86563786a1f1`, also failed: fetching the pinned
python3-setup-ovs source failed. The repository and commit were verified to exist
and a later CQFD network probe succeeded. The user authorized omitting this
component for the cost evaluation rather than investigating the fetch further.

The `host_efi` evaluation image now omits `python3-setup-ovs` and
`system-config-ovs`, whose systemd service requires `/usr/bin/setup_ovs`.
Its otherwise unused runtime dependency also pulled the helper into BitBake's
recipe graph, so an evaluation-only system-config append removes that dependency.
Open vSwitch, libvirt and QEMU remain in the workload. This image cannot validate
normal SEAPATH OVS boot configuration; results concern compilation cost only.
The other image definitions are unchanged and still explicitly install the helper.

Tag `yocto-ec2-2026-10-19-v2` pins the revised evaluation baseline. The v1 tag is
retained unchanged. A new successful full build is required before reusing caches.
