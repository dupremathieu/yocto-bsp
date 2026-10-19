#!/usr/bin/env python3
"""Publish caches only after the watched local build succeeds and stays aligned."""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import subprocess
import time


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evaluation", type=Path)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    base = args.evaluation.resolve()
    with (base / "publish.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("Cache publication is already running") from None
        exit_path = base / "container-exit.json"
        if not exit_path.exists():
            raise SystemExit("Local build has not finished; cache publication refused")
        result = json.loads(exit_path.read_text())
        if result["wait_returncode"] != 0 or str(result["container_exit_code"]) != "0":
            raise SystemExit("Local build did not succeed; cache publication refused")
        if sha(root / "seapath.conf") != (base / "config.sha256").read_text().strip():
            raise SystemExit("Local build configuration changed; cache publication refused")
        for name, expected in json.loads((base / "bsp-inputs.json").read_text()).items():
            if sha(root / name) != expected:
                raise SystemExit(f"BSP build input changed during local build: {name}")
        for source in json.loads((base / "sources.json").read_text()):
            git = ["git", "-C", str(root / source["path"])]
            head = subprocess.check_output(git + ["rev-parse", "HEAD"], text=True).strip()
            diff = subprocess.check_output(git + ["diff", "HEAD", "--binary"])
            if head != source["head"] or hashlib.sha256(diff).hexdigest() != source["diff_sha256"]:
                raise SystemExit(f"Source changed during local build: {source['path']}")
        # A stopped container alone does not prove that the requested image exists.
        images = list((root / "build/tmp/deploy/images/seapath-hypervisor").glob("seapath-host-efi-image*.qcow2"))
        if not any(p.is_file() for p in images):
            raise SystemExit("Expected host_efi qcow2 image is missing")
        if args.check_only:
            print("Successful local build, pinned sources and configuration verified")
            return
        if (base / "uploaded.json").exists():
            raise SystemExit("Cache was already published; reuse uploaded.json")

        aws = ["aws", "--profile", "seapath", "--region", "eu-west-3"]
        bucket = subprocess.check_output(
            ["terraform", "-chdir=" + str(root / "infra/aws-runner"), "output", "-raw", "cache_bucket"],
            text=True,
        ).strip()
        if not bucket.startswith("seapath-yocto-ci-cache-"):
            raise SystemExit("Unexpected cache bucket; stopped")
        prefix = "local-host-efi-" + result["container"]
        for folder, name in (("downloads", "downloads"), ("sstate-cache", "sstate")):
            print(f"Uploading {name} from the successful local build", flush=True)
            tar = subprocess.Popen(["tar", "--exclude=*.lock", "-cf", "-", "-C", str(root / "build" / folder), "."], stdout=subprocess.PIPE)
            try:
                subprocess.run(aws + ["s3", "cp", "-", f"s3://{bucket}/{prefix}/{name}.tar",
                                     "--expected-size", "322122547200", "--only-show-errors"],
                               stdin=tar.stdout, check=True)
            finally:
                tar.stdout.close()
                if tar.poll() is None:
                    # Wait for EOF normally; on failed upload the closed pipe stops tar.
                    tar.wait()
            if tar.returncode:
                raise SystemExit(f"Cache archive changed or failed: {name}")
        for name in ("source-lock.xml", "seapath.conf", "sources.json", "local-manifest.xml"):
            subprocess.run(aws + ["s3", "cp", str(base / name), f"s3://{bucket}/{prefix}/{name}", "--only-show-errors"], check=True)
        metadata = {
            "local_build_succeeded": True, "container_exit_code": 0, "flavor": "host_efi",
            "container": result["container"], "prefix": prefix, "bucket": bucket,
            "source_lock_sha256": sha(base / "source-lock.xml"),
            "config_sha256": sha(base / "seapath.conf"), "uploaded_at": time.time(),
        }
        complete = base / "complete.json"
        complete.write_text(json.dumps(metadata, indent=2))
        subprocess.run(aws + ["s3", "cp", str(complete), f"s3://{bucket}/{prefix}/complete.json", "--only-show-errors"], check=True)
        (base / "uploaded.json").write_text(json.dumps(metadata, indent=2))
        print("Verified local cache published; ready for the reference build")


if __name__ == "__main__":
    main()
