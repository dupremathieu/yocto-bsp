#!/usr/bin/env python3
"""Fetch the pinned upstream Lambda release assets used by this deployment."""
import hashlib
from pathlib import Path
import urllib.request

VERSION = "v7.11.0"
SHA256 = {
    "webhook": "7dbbb262757fdcc4be8928250a614fda4deb85cbd02e50bbad0f6538426f3bd3",
    "runners": "7b262395ed7683b7940f2efbd9e234a8712fb33ba71e896db356204aeb0a3f53",
    "runner-binaries-syncer": "d56b60477be52fcd94c3b35f39d1a6770420661d539eda2ea3ae920e5c5f1ea2",
}


def main():
    artifacts = Path(__file__).resolve().parent / ".artifacts"
    artifacts.mkdir(exist_ok=True)
    for name, expected in SHA256.items():
        path = artifacts / f"{name}.zip"
        if not path.exists():
            url = (
                "https://github.com/github-aws-runners/terraform-aws-github-runner/"
                f"releases/download/{VERSION}/{name}.zip"
            )
            urllib.request.urlretrieve(url, path)
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise SystemExit(f"Checksum mismatch for {path}; stopped")
        print(f"Verified {name}.zip ({VERSION})")


if __name__ == "__main__":
    main()
