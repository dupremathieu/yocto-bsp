#!/usr/bin/env python3
"""Validate an owned GitHub App and keep its credentials outside Terraform state."""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def encode(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=")


def app_jwt(app_id, private_key):
    now = int(time.time())
    header = encode(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    payload = encode(json.dumps({"iat": now - 60, "exp": now + 540, "iss": app_id}).encode())
    message = header + b"." + payload
    signature = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(private_key)],
        input=message, capture_output=True, check=True,
    ).stdout
    return (message + b"." + encode(signature)).decode()


def github_get(path, token):
    request = urllib.request.Request(
        "https://api.github.com" + path,
        headers={"Authorization": "Bearer " + token,
                 "Accept": "application/vnd.github+json",
                 "User-Agent": "seapath-ec2-runner-setup"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise SystemExit(f"GitHub API {path} returned HTTP {error.code}; credentials hidden") from None


def aws_json(args, command, document=None):
    base = ["aws", "--profile", args.aws_profile, "--region", args.region, "--output", "json"]
    with tempfile.TemporaryDirectory(prefix="seapath-app-") as directory:
        if document is not None:
            path = Path(directory) / "request.json"
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w") as stream:
                json.dump(document, stream)
            command = command + ["--cli-input-json", "file://" + str(path)]
        result = subprocess.run(base + command, text=True, capture_output=True)
    if result.returncode:
        raise SystemExit(f"AWS operation {command[:2]} failed; output suppressed to protect credentials")
    return json.loads(result.stdout) if result.stdout.strip() else {}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-id", required=True)
    parser.add_argument("--private-key", type=Path, required=True)
    parser.add_argument("--repository", default="dupremathieu/virtual-cluster")
    parser.add_argument("--aws-profile", default="seapath")
    parser.add_argument("--region", default="eu-west-3")
    parser.add_argument("--ssm-path", default="/seapath/ec2-runner/github-app")
    parser.add_argument("--webhook-url", help="After terraform apply, create/update the repository webhook")
    args = parser.parse_args()
    if not args.app_id.isdecimal() or not args.private_key.is_file():
        parser.error("Provide a numeric App ID and an existing private key file")
    token = app_jwt(args.app_id, args.private_key)
    app = github_get("/app", token)
    if str(app["id"]) != args.app_id:
        raise SystemExit("The private key does not match the supplied App ID")
    for permission, level in {"actions": "read", "checks": "read", "administration": "write"}.items():
        actual = app.get("permissions", {}).get(permission)
        if actual != level and not (level == "read" and actual == "write"):
            raise SystemExit(f"GitHub App needs {permission}={level}")
    installation = github_get(f"/repos/{args.repository}/installation", token)
    print(f"Validated GitHub App {app['slug']} and repository installation {installation['id']}")

    # Keep the same webhook secret on subsequent setup runs.
    name = args.ssm_path + "/webhook-secret"
    listing = aws_json(args, ["ssm", "describe-parameters", "--parameter-filters",
                            f"Key=Name,Option=Equals,Values={name}"])
    if listing.get("Parameters"):
        webhook_secret = aws_json(args, ["ssm", "get-parameter", "--name", name,
                                         "--with-decryption"])["Parameter"]["Value"]
    else:
        webhook_secret = secrets.token_hex(32)
    values = {"id": args.app_id,
              "key-base64": base64.b64encode(args.private_key.read_bytes()).decode(),
              "webhook-secret": webhook_secret}
    for suffix, value in values.items():
        aws_json(args, ["ssm", "put-parameter"], {
            "Name": args.ssm_path + "/" + suffix, "Value": value,
            "Type": "SecureString", "Overwrite": True, "Tier": "Intelligent-Tiering",
        })
    print("GitHub App credentials stored in SSM; no secret values printed")

    if args.webhook_url:
        if not args.webhook_url.startswith("https://"):
            parser.error("The repository webhook URL must use HTTPS")
        endpoint = f"repos/{args.repository}/hooks"
        result = subprocess.run(["gh", "api", endpoint], capture_output=True, text=True, check=True)
        existing = next((hook for hook in json.loads(result.stdout)
                         if hook.get("config", {}).get("url") == args.webhook_url), None)
        document = {"name": "web", "active": True, "events": ["workflow_job"],
                    "config": {"url": args.webhook_url, "content_type": "json",
                               "secret": webhook_secret, "insecure_ssl": "0"}}
        if existing:
            endpoint += "/" + str(existing["id"])
        with tempfile.TemporaryDirectory(prefix="seapath-hook-") as directory:
            path = Path(directory) / "request.json"
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w") as stream:
                json.dump(document, stream)
            result = subprocess.run(["gh", "api", endpoint, "--method", "PATCH" if existing else "POST",
                                     "--input", str(path)], capture_output=True, text=True)
        if result.returncode:
            raise SystemExit("Repository webhook configuration failed; response hidden")
        hook = json.loads(result.stdout)
        print(f"Repository workflow_job webhook {hook['id']} configured")


if __name__ == "__main__":
    main()
