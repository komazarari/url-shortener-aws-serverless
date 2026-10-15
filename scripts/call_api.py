#!/usr/bin/env python3
"""Call the registration API's Function URL with SigV4.

The Function URL uses AuthType = AWS_IAM, so requests must be signed. curl
cannot do that on its own; this uses the credentials botocore already resolves
(env vars, profile, SSO session, ...).

Usage:
    # register
    ./scripts/call_api.py post https://example.com/some/long/url

    # look up
    ./scripts/call_api.py get 4103d7b4

    # explicit endpoint (otherwise read from terraform output)
    API_URL=https://xxxx.lambda-url.ap-northeast-1.on.aws ./scripts/call_api.py get 4103d7b4

Requires boto3/botocore, which ship with the AWS CLI.
"""

import argparse
import json
import os
import subprocess
import sys
from urllib.parse import urlsplit

try:
    import botocore.session
    from botocore.auth import SigV4Auth
    from botocore.awsrequest import AWSRequest
except ImportError:
    sys.exit("botocore is required: pip install botocore")

import urllib.request
import urllib.error


def discover_endpoint() -> str:
    """Prefer $API_URL, else ask terraform."""
    if os.environ.get("API_URL"):
        return os.environ["API_URL"].rstrip("/")

    tf_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "terraform")
    try:
        out = subprocess.run(
            ["terraform", "output", "-raw", "api_function_url"],
            cwd=tf_dir,
            capture_output=True,
            text=True,
            check=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        sys.exit(
            "could not determine the endpoint. Set API_URL, or run this from a "
            f"working terraform directory. ({exc})"
        )
    return out.stdout.strip().rstrip("/")


def signed_request(method: str, url: str, body: str | None, region: str | None):
    session = botocore.session.get_session()
    credentials = session.get_credentials()
    if credentials is None:
        sys.exit("no AWS credentials found")
    credentials = credentials.get_frozen_credentials()

    region = region or session.get_config_variable("region")
    if not region:
        # Function URLs embed the region: <id>.lambda-url.<region>.on.aws
        host_parts = urlsplit(url).netloc.split(".")
        region = host_parts[2] if len(host_parts) > 3 else None
    if not region:
        sys.exit("could not determine the AWS region; set AWS_REGION")

    headers = {}
    if body is not None:
        headers["content-type"] = "application/json"

    request = AWSRequest(method=method, url=url, data=body, headers=headers)
    # "lambda" is the signing name for Function URLs.
    SigV4Auth(credentials, "lambda", region).add_auth(request)

    prepared = urllib.request.Request(
        url,
        data=body.encode() if body else None,
        headers=dict(request.headers),
        method=method,
    )
    try:
        with urllib.request.urlopen(prepared) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as err:
        return err.code, err.read().decode()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_post = sub.add_parser("post", help="register a URL")
    p_post.add_argument("url")

    p_get = sub.add_parser("get", help="look up a key")
    p_get.add_argument("key")

    parser.add_argument("--region", default=None)
    args = parser.parse_args()

    endpoint = discover_endpoint()

    if args.command == "post":
        status, text = signed_request(
            "POST", f"{endpoint}/api/links", json.dumps({"url": args.url}), args.region
        )
    else:
        status, text = signed_request(
            "GET", f"{endpoint}/api/links/{args.key}", None, args.region
        )

    print(f"HTTP {status}")
    try:
        print(json.dumps(json.loads(text), indent=2, ensure_ascii=False))
    except ValueError:
        print(text)

    return 0 if status < 400 else 1


if __name__ == "__main__":
    sys.exit(main())
