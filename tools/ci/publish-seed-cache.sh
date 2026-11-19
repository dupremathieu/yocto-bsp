#!/bin/bash
# Publish the caches of a successful local seed build for one EC2 reference run.
#
# Usage: publish-seed-cache.sh <workspace> <cache-dir> <bucket> <flavor>
#
# <workspace> is a repo checkout synced on the manifest the EC2 run will use,
# with .ec2-seed/{build-exit.txt,seapath.conf} written by the seed build.
# <cache-dir> holds the downloads/ and sstate/ directories it used. Symlinks
# to mirror caches are dereferenced, so only objects of this build are sent.
# AWS credentials come from the environment (AWS_PROFILE, aws login...).
set -euo pipefail

workspace=$(realpath "$1")
cache=$(realpath "$2")
bucket=$3
flavor=$4
seed="$workspace/.ec2-seed"
aws=(aws --region eu-west-3)

[[ "$bucket" == seapath-yocto-ci-cache-* ]] || { echo 'Unexpected bucket' >&2; exit 1; }
[ "$(cat "$seed/build-exit.txt")" = 0 ] || { echo 'Seed build did not succeed' >&2; exit 1; }
case "$flavor" in
    *_swu) pattern='*.swu' ;;
    *) pattern='*.qcow2' ;;
esac
find "$workspace/build/tmp/deploy/images" -type f -name "$pattern" | grep -q . ||
    { echo "No $pattern image in the seed build" >&2; exit 1; }

# Pin what the seed build used; build-ec2.sh compares it with its own sync.
(cd "$workspace" && repo manifest -r) > "$seed/local-manifest.xml"
python3 -I - "$seed/local-manifest.xml" "$seed/source-lock.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
out = ET.Element('manifest')
for p in ET.parse(sys.argv[1]).getroot().findall('project'):
    path = p.get('path', '')
    if path == '.' or path.startswith('sources/'):
        ET.SubElement(out, 'extend-project', name=p.get('name'), revision=p.get('revision'))
ET.indent(out)
ET.ElementTree(out).write(sys.argv[2], encoding='UTF-8', xml_declaration=True)
PY
for d in "$workspace" "$workspace"/sources/*/; do
    # Patched layers are restored by build.sh from patches/; anything else is a local edit.
    git -C "$d" diff --quiet HEAD -- . ':!*.orig' 2>/dev/null || case "$d" in
        */meta-cgl/|*/meta-secure-core/) ;;
        *) echo "Uncommitted change in $d" >&2; exit 1 ;;
    esac
done

prefix="local-${flavor//_/-}-$(date -u +%Y%m%d%H%M%S | sha1sum | cut -c1-12)"
python3 -I -c 'import sqlite3,sys; s=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro",uri=True); s.backup(sqlite3.connect(sys.argv[2]))' \
    "$workspace/build/cache/hashserv.db" "$seed/hashserv.db"

for name in downloads sstate; do
    echo "Uploading $name to s3://$bucket/$prefix/" >&2
    tar --dereference --exclude='*.lock' -cf - -C "$cache/$name" . |
        "${aws[@]}" s3 cp - "s3://$bucket/$prefix/$name.tar" \
            --expected-size 322122547200 --only-show-errors
done
for name in source-lock.xml seapath.conf local-manifest.xml hashserv.db; do
    "${aws[@]}" s3 cp "$seed/$name" "s3://$bucket/$prefix/$name" --only-show-errors
done
jq -n --arg prefix "$prefix" --arg flavor "$flavor" --arg bucket "$bucket" \
    --arg lock "$(sha256sum < "$seed/source-lock.xml" | cut -d' ' -f1)" \
    --arg conf "$(sha256sum < "$seed/seapath.conf" | cut -d' ' -f1)" \
    '{local_build_succeeded: true, container_exit_code: 0, flavor: $flavor,
      prefix: $prefix, bucket: $bucket, hashserv: true,
      source_lock_sha256: $lock, config_sha256: $conf, uploaded_at: (now | todate)}' \
    > "$seed/complete.json"
# Written last: build-ec2.sh accepts the prefix only once this marker exists.
"${aws[@]}" s3 cp "$seed/complete.json" "s3://$bucket/$prefix/complete.json" --only-show-errors
echo "$prefix"
