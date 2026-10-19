#!/bin/bash
# Run only in a fresh ephemeral EC2 runner workspace, never in a developer build.
set -euo pipefail
: "${GITHUB_WORKSPACE:?}" "${CI_RESULTS:?}" "${CI_ORIGIN_URL:?}" "${CI_ORIGIN_SHA:?}" "${CI_CACHE_BUCKET:?}"
export AWS_DEFAULT_REGION=eu-west-3

case "${CI_FLAVOR:-host_efi}" in
    host_efi|host_standalone_efi|guest_efi|observer_efi) flavors=("$CI_FLAVOR") ;;
    *) echo 'Unsupported image selection' >&2; exit 1 ;;
esac

workspace="$GITHUB_WORKSPACE/workspace-bitbake"
cache="$GITHUB_WORKSPACE/yocto-cache"
# Fail instead of deleting an existing build or hiding insufficient root storage.
test ! -e "$workspace"
available_kib=$(df --output=avail -k "$GITHUB_WORKSPACE" | tail -1)
if (( available_kib < 250 * 1024 * 1024 )); then
    echo 'At least 250 GiB free space is required for this evaluation.' >&2
    exit 1
fi
mkdir -p "$workspace" "$cache/downloads" "$cache/sstate" "$CI_RESULTS"
printf 'stage\tseconds\texit_code\n' > "$CI_RESULTS/timings.tsv"

monitor_resources() {
    while true; do
        date -u +%FT%TZ
        df -B1 "$GITHUB_WORKSPACE"
        free -b
        docker stats --no-stream --format '{{json .}}'
        sleep 30
    done
}
monitor_resources > "$CI_RESULTS/resource-samples.log" 2>&1 &
monitor_pid=$!
trap 'kill "$monitor_pid" 2>/dev/null || true' EXIT

timed() {
    local label=$1 started result=0
    shift
    started=$SECONDS
    # Do not wrap shell functions in `if` or `||`: that disables errexit inside them.
    set +e
    ( set -e; "$@" ) 2>&1 | tee "$CI_RESULTS/$label.log"
    result=${PIPESTATUS[0]}
    set -e
    printf '%s\t%s\t%s\n' "$label" "$((SECONDS - started))" "$result" >> "$CI_RESULTS/timings.tsv"
    return "$result"
}

sync_sources() {
    if [ -n "${CI_LOCAL_CACHE_PREFIX:-}" ]; then
        [[ "$CI_LOCAL_CACHE_PREFIX" =~ ^local-host-efi-[a-f0-9]+$ ]]
        [ "$CI_FLAVOR" = host_efi ]
        aws s3 cp "s3://$CI_CACHE_BUCKET/$CI_LOCAL_CACHE_PREFIX/complete.json" \
            "$CI_RESULTS/local-cache-complete.json" --no-progress
        jq -e '.local_build_succeeded == true and .container_exit_code == 0 and .flavor == "host_efi"' \
            "$CI_RESULTS/local-cache-complete.json" >/dev/null
        aws s3 cp "s3://$CI_CACHE_BUCKET/$CI_LOCAL_CACHE_PREFIX/source-lock.xml" \
            "$CI_RESULTS/source-lock.xml" --no-progress
        aws s3 cp "s3://$CI_CACHE_BUCKET/$CI_LOCAL_CACHE_PREFIX/seapath.conf" \
            "$CI_RESULTS/local-seapath.conf" --no-progress
        printf '%s  %s\n' "$(jq -r .source_lock_sha256 "$CI_RESULTS/local-cache-complete.json")" \
            "$CI_RESULTS/source-lock.xml" | sha256sum -c -
        printf '%s  %s\n' "$(jq -r .config_sha256 "$CI_RESULTS/local-cache-complete.json")" \
            "$CI_RESULTS/local-seapath.conf" | sha256sum -c -
    fi
    repo init -u "${CI_MANIFEST_URL:-https://github.com/dupremathieu/repo-manifest.git}" \
        -b "${CI_MANIFEST_REF:-refs/tags/yocto-ec2-2026-10-19-v1}" \
        -m "${CI_MANIFEST_FILE:-wrynose-ec2.xml}"
    if [ -n "${CI_LOCAL_CACHE_PREFIX:-}" ]; then
        mkdir -p .repo/local_manifests
        cp "$CI_RESULTS/source-lock.xml" .repo/local_manifests/evaluation-lock.xml
    fi
    repo sync -j4 --fail-fast
    # Build the pinned BSP; the workflow driver lives in the separate ci checkout.
    printf '%s\n' "$CI_ORIGIN_SHA" > "$CI_RESULTS/workflow.sha"
    repo manifest -r -o "$CI_RESULTS/manifest.xml"
    if [ -n "${CI_LOCAL_CACHE_PREFIX:-}" ]; then
        python3 - "$CI_RESULTS/source-lock.xml" "$CI_RESULTS/manifest.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
locked = {p.get('name'): p.get('revision') for p in ET.parse(sys.argv[1]).getroot().findall('extend-project')}
actual = {p.get('name'): p.get('revision') for p in ET.parse(sys.argv[2]).getroot().findall('project')
          if p.get('path', '') == '.' or p.get('path', '').startswith('sources/')}
if actual != locked:
    raise SystemExit('Source revisions differ from the successful local build')
PY
    fi
    git rev-parse HEAD > "$CI_RESULTS/yocto-bsp.sha"
    git -C sources/meta-seapath rev-parse HEAD > "$CI_RESULTS/meta-seapath.sha"
}

restore_cache() {
    local prefix marker="caches/$CI_FLAVOR/latest.json" existing
    if [ -n "${CI_LOCAL_CACHE_PREFIX:-}" ]; then
        prefix=$CI_LOCAL_CACHE_PREFIX
        cp "$CI_RESULTS/local-cache-complete.json" "$CI_RESULTS/cache-source.json"
    else
        existing=$(aws s3api list-objects-v2 --bucket "$CI_CACHE_BUCKET" --prefix "$marker" \
            --query 'Contents[].Key' --output text)
        if [ -n "$existing" ] && [ "$existing" != None ]; then
            aws s3 cp "s3://$CI_CACHE_BUCKET/$marker" "$CI_RESULTS/cache-source.json" --no-progress
            prefix=$(jq -er --arg flavor "$CI_FLAVOR" \
                'select(.reference_build_succeeded == true and .flavor == $flavor) | .prefix' \
                "$CI_RESULTS/cache-source.json")
            case "$prefix" in
                "caches/$CI_FLAVOR/"*) ;;
                *) echo 'Invalid published cache prefix' >&2; return 1 ;;
            esac
        else
            printf '{"kind":"empty-cache-first-aws-build"}\n' > "$CI_RESULTS/cache-source.json"
            echo 'No verified AWS cache exists; populate it with a fresh build.'
            return 0
        fi
    fi
    aws s3 cp "s3://$CI_CACHE_BUCKET/$prefix/downloads.tar" - --no-progress \
        | tar -xf - -C "$cache/downloads" --no-same-owner
    aws s3 cp "s3://$CI_CACHE_BUCKET/$prefix/sstate.tar" - --no-progress \
        | tar -xf - -C "$cache/sstate" --no-same-owner
    du -sh "$cache"/* > "$CI_RESULTS/cache-restored-size.txt"
}

save_cache() {
    local prefix="caches/$CI_FLAVOR/$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
    # Stream archives to preserve permissions and links, without another disk copy.
    # Expected size selects multipart chunks large enough for a disk up to 300 GiB.
    tar -cf - -C "$cache/downloads" . | aws s3 cp - \
        "s3://$CI_CACHE_BUCKET/$prefix/downloads.tar" --expected-size 322122547200 --no-progress
    tar -cf - -C "$cache/sstate" . | aws s3 cp - \
        "s3://$CI_CACHE_BUCKET/$prefix/sstate.tar" --expected-size 322122547200 --no-progress
    jq -n --arg prefix "$prefix" --arg flavor "$CI_FLAVOR" --arg sha "$(git rev-parse HEAD)" \
        '{prefix:$prefix,flavor:$flavor,sha:$sha,reference_build_succeeded:true}' \
        > "$CI_RESULTS/cache-published.json"
    # Publish the pointer only after both archives and the reference build succeed.
    aws s3 cp "$CI_RESULTS/cache-published.json" \
        "s3://$CI_CACHE_BUCKET/caches/$CI_FLAVOR/latest.json" --no-progress
    du -sh "$cache"/* > "$CI_RESULTS/cache-final-size.txt"
}

cd "$workspace"
git config --global user.name 'SEAPATH CI'
git config --global user.email 'ci@seapath.invalid'
timed source-sync sync_sources
timed cache-restore restore_cache

# Caches are restored from S3, used locally, then published back to S3.
# CQFD splits these arguments on spaces; GitHub's EC2 workspace has no spaces.
export CQFD_EXTRA_RUN_ARGS="-v $cache/downloads:/mnt/dl -e DL_DIR=/mnt/dl -v $cache/sstate:/mnt/sstate -e SSTATE_DIR=/mnt/sstate -e BB_NUMBER_THREADS=4 -e PARALLEL_MAKE=-j4 -e SEAPATH_PARALLEL_MAKE=4 -e SEAPATH_SECCOMPILE_MANIFEST_SKIP=1"
timed container-init cqfd init
mkdir -p keys
touch keys/ansible_public_ssh_key.pub
if [ -n "${CI_LOCAL_CACHE_PREFIX:-}" ]; then
    cp "$CI_RESULTS/local-seapath.conf" seapath.conf
else
    cp seapath.conf.sample seapath.conf
fi
cp seapath.conf "$CI_RESULTS/seapath.conf.txt"

for flavor in "${flavors[@]}"; do
    if [ -z "${CI_LOCAL_CACHE_PREFIX:-}" ]; then
        timed "$flavor-populate" /usr/bin/time -v -o "$CI_RESULTS/$flavor-populate-resources.txt" cqfd -b "$flavor"
        # Consume sstate, not existing task stamps, for the reference build.
        timed clean-build cqfd run 'rm -rf build'
    fi
    timed "$flavor-reference" /usr/bin/time -v -o "$CI_RESULTS/$flavor-reference-resources.txt" cqfd -b "$flavor"
    awk '/Sstate summary:|Tasks Summary:/' "$CI_RESULTS/$flavor-reference.log" \
        > "$CI_RESULTS/$flavor-reference-cache-summary.txt"
    # Record image sizes and digests without uploading large firmware images.
    find build/tmp/deploy/images -type f \
        \( -name '*.qcow2' -o -name '*.wic*' -o -name '*.spdx.json' \) \
        -printf '%p\t%s bytes\n' > "$CI_RESULTS/$flavor-images.txt"
    find build/tmp/deploy/images -type f -name '*.qcow2' -exec sha256sum {} + \
        > "$CI_RESULTS/$flavor-images.sha256"
done
if [ -z "${CI_LOCAL_CACHE_PREFIX:-}" ]; then
    timed cache-publish save_cache
else
    # This one-off evaluation deletes its S3 cache after results are recovered.
    du -sh "$cache"/* > "$CI_RESULTS/cache-final-size.txt"
fi
