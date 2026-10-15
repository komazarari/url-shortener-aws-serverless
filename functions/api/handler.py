"""URL shortener registration API.

Runs behind a Lambda Function URL (AuthType = AWS_IAM).

Routes:
    POST /api/links           register a URL, return its short key
    GET  /api/links/{key}     look up what a key points at

The key is the first 40 bits of the SHA-256 of the target URL, rendered as 10
lowercase hex digits. Objects are 0 bytes; the target lives in the
x-amz-website-redirect-location metadata, which the S3 website endpoint turns
into a 301.

Keys minted before this scheme are CRC32 and eight digits long. They still
resolve -- the redirect path never ran this code, and lookups accept both
lengths -- but re-registering a URL shortened under the old scheme now mints a
second key pointing at the same target. That is accepted: the old link keeps
working, and nothing but idempotency across the cutover is lost.

Pure logic (normalisation, key derivation, collision resolution) is kept free
of AWS calls so it can be unit tested without network access.
"""

from __future__ import annotations

import base64
import hashlib
import ipaddress
import json
import logging
import os
import re
from datetime import datetime, timezone
from typing import Callable, Optional, Tuple
from urllib.parse import urlsplit, urlunsplit

# The SDK is always present on Lambda, where importing here (during INIT) is
# cheaper than doing it on the first invocation. It is absent when running the
# unit tests, which never reach the S3 adapters.
try:
    import boto3
    from botocore.exceptions import ClientError
except ImportError:  # pragma: no cover - exercised only by the unit tests
    boto3 = None

    class ClientError(Exception):  # type: ignore[no-redef]
        """Stand-in with the same constructor shape as botocore's."""

        def __init__(self, error_response=None, operation_name=None):
            super().__init__(str(error_response))
            self.response = error_response or {}
            self.operation_name = operation_name


LOG = logging.getLogger()
LOG.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

MAX_URL_LENGTH = 2048
ALLOWED_SCHEMES = ("http", "https")
DEFAULT_PORTS = {"http": 80, "https": 443}

# 40 bits. Eight hex digits -- the CRC32 this replaced -- is 4.3 billion keys,
# small enough that a short link guarding a capability URL could be found by
# sweeping the whole space. Ten digits is 256 times the room and, on a short
# domain, encodes to the same QR version, which is what the keys exist for.
KEY_BYTES = 5

# Both lengths are accepted on lookup: 10 for current keys, 8 for the CRC32
# ones minted before the switch. Those links are already printed on things.
KEY_PATTERN = re.compile(r"^([0-9a-f]{8}|[0-9a-f]{10})$")
LINK_PATH = re.compile(r"^/api/links/([^/]+)$")

_s3 = None


def _client():
    global _s3
    if _s3 is None:
        if boto3 is None:
            raise ApiError(500, "internal_error", "the AWS SDK is unavailable")
        _s3 = boto3.client("s3")
    return _s3


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


# ---------------------------------------------------------------------------
# Pure logic
# ---------------------------------------------------------------------------


def _reject_non_public_host(host: str) -> None:
    if host == "localhost" or host.endswith(".localhost"):
        raise ApiError(400, "invalid_url", "localhost is not a valid redirect target")
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return  # a regular domain name
    if (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_reserved
        or ip.is_multicast
        or ip.is_unspecified
    ):
        raise ApiError(400, "invalid_url", "non-public IP addresses are not allowed")


def normalize_url(raw: object) -> str:
    """Validate and normalise a target URL.

    Normalisation is deliberately conservative: scheme and host are lowercased
    and default ports dropped, but the query string is never reordered or
    stripped, because that could change what the target site does.
    """
    if not isinstance(raw, str):
        raise ApiError(400, "invalid_url", "url must be a string")

    url = raw.strip()
    if not url:
        raise ApiError(400, "invalid_url", "url is required")
    if len(url) > MAX_URL_LENGTH:
        raise ApiError(
            400, "invalid_url", f"url must be {MAX_URL_LENGTH} characters or fewer"
        )

    parts = urlsplit(url)

    scheme = parts.scheme.lower()
    if scheme not in ALLOWED_SCHEMES:
        raise ApiError(400, "invalid_url", "only http and https URLs are allowed")

    # user:pass@host is a classic phishing disguise (https://trusted.com@evil.com).
    if parts.username is not None or parts.password is not None:
        raise ApiError(400, "invalid_url", "credentials in the URL are not allowed")

    try:
        host = parts.hostname
    except ValueError as exc:  # malformed IPv6 literal, bad port, ...
        raise ApiError(400, "invalid_url", "could not parse the host") from exc
    if not host:
        raise ApiError(400, "invalid_url", "url must contain a host")
    host = host.lower()
    _reject_non_public_host(host)

    try:
        port = parts.port
    except ValueError as exc:
        raise ApiError(400, "invalid_url", "invalid port") from exc

    netloc = f"[{host}]" if _is_ipv6(host) else host
    if port is not None and port != DEFAULT_PORTS[scheme]:
        netloc = f"{netloc}:{port}"

    path = parts.path or "/"
    return urlunsplit((scheme, netloc, path, parts.query, parts.fragment))


def _is_ipv6(host: str) -> bool:
    try:
        return isinstance(ipaddress.ip_address(host), ipaddress.IPv6Address)
    except ValueError:
        return False


def key_material(url: str, attempt: int) -> str:
    """Hash input for a given attempt.

    Attempt 0 hashes the URL itself. Later attempts append a NUL separated
    counter. NUL cannot appear in a URL, so `url` with a "#1" fragment can
    never collide with attempt 1 of the same URL.
    """
    return url if attempt == 0 else f"{url}\x00{attempt}"


def compute_key(url: str, attempt: int = 0) -> str:
    """Truncated SHA-256, KEY_BYTES wide.

    A checksum would do everything asked of it here -- the key only has to be
    deterministic and spread out -- but CRC32 caps the key at 32 bits and is
    trivially collidable by anyone who wants a specific key. Neither matters
    while registration is authenticated; both matter once a key is the only
    thing standing between a passer-by and a share URL.
    """
    digest = hashlib.sha256(key_material(url, attempt).encode("utf-8")).digest()
    return digest[:KEY_BYTES].hex()


def resolve_key(
    url: str,
    lookup: Callable[[str], Optional[str]],
    store: Callable[[str, str], bool],
    max_attempts: int = 16,
) -> Tuple[str, bool]:
    """Find a free key for `url`, or reuse the existing one.

    `lookup(key)` returns the target URL recorded for a key, or None.
    `store(key, url)` writes the object and returns False if the key was taken
    in the meantime (S3 conditional write lost the race).

    Returns (key, existed_already).
    """
    for attempt in range(max_attempts):
        key = compute_key(url, attempt)

        current = lookup(key)
        if current == url:
            return key, True  # idempotent: same URL, same key

        if current is None:
            if store(key, url):
                return key, False
            # Lost a race. Re-read: it may now hold our URL, or someone else's.
            if lookup(key) == url:
                return key, True

        # Real collision (or the slot was taken by a different URL). Try again.

    raise ApiError(
        409,
        "collision_exhausted",
        f"could not find a free key after {max_attempts} attempts",
    )


# ---------------------------------------------------------------------------
# S3 adapters
# ---------------------------------------------------------------------------

_NOT_FOUND_CODES = {"404", "NoSuchKey", "NotFound"}
_PRECONDITION_CODES = {"412", "PreconditionFailed"}
_FORBIDDEN_CODES = {"403", "AccessDenied", "Forbidden"}


def _bucket() -> str:
    bucket = os.environ.get("BUCKET")
    if not bucket:
        raise ApiError(500, "internal_error", "BUCKET is not configured")
    return bucket


def head_metadata(key: str) -> Optional[dict]:
    """HEAD an object, or None if it does not exist."""
    try:
        return _client().head_object(Bucket=_bucket(), Key=key)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code")
        if code in _NOT_FOUND_CODES:
            return None
        if code in _FORBIDDEN_CODES:
            # S3 answers 403 rather than 404 for a missing key when the caller
            # lacks s3:ListBucket, so a denial here is ambiguous. Say so,
            # because the stack trace on its own points at the wrong thing.
            raise ApiError(
                500,
                "internal_error",
                "S3 denied HeadObject. Check that the execution role has "
                "s3:GetObject on the objects and s3:ListBucket on the bucket; "
                "without the latter, missing keys are reported as 403.",
            ) from exc
        raise


def lookup_target(key: str) -> Optional[str]:
    head = head_metadata(key)
    return head.get("WebsiteRedirectLocation") if head else None


def make_store(created_by: str, created_at: str) -> Callable[[str, str], bool]:
    def store(key: str, url: str) -> bool:
        try:
            _client().put_object(
                Bucket=_bucket(),
                Key=key,
                Body=b"",
                WebsiteRedirectLocation=url,
                ContentType="text/plain",
                CacheControl=os.environ.get("OBJECT_CACHE_CONTROL", "max-age=300"),
                Metadata={"created-at": created_at, "created-by": created_by},
                # Conditional write: fail instead of clobbering an existing key.
                IfNoneMatch="*",
            )
            return True
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") in _PRECONDITION_CODES:
                return False
            raise

    return store


# ---------------------------------------------------------------------------
# HTTP plumbing
# ---------------------------------------------------------------------------


def _response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {
            "content-type": "application/json; charset=utf-8",
            "cache-control": "no-store",
        },
        "body": json.dumps(body, ensure_ascii=False),
    }


def _request_body(event: dict) -> dict:
    raw = event.get("body")
    if raw is None:
        raise ApiError(400, "invalid_request", "request body is required")
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")

    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    content_type = headers.get("content-type", "")
    # Requiring JSON blocks browser "simple requests", which is a cheap CSRF guard.
    if "application/json" not in content_type.lower():
        raise ApiError(415, "invalid_request", "content-type must be application/json")

    try:
        parsed = json.loads(raw)
    except (ValueError, UnicodeDecodeError) as exc:
        raise ApiError(400, "invalid_request", "body must be valid JSON") from exc
    if not isinstance(parsed, dict):
        raise ApiError(400, "invalid_request", "body must be a JSON object")
    return parsed


def _caller(event: dict) -> str:
    """Best-effort identity of the caller.

    With AuthType = AWS_IAM the Function URL populates the IAM authorizer.
    Once Lambda@Edge OIDC is in front, this should switch to the OIDC subject.
    """
    iam = (
        (event.get("requestContext") or {}).get("authorizer", {}).get("iam", {})
    )
    return iam.get("userId") or iam.get("arn") or "unknown"


def _short_url(key: str) -> str:
    domain = os.environ.get("SHORT_DOMAIN")
    if not domain:
        raise ApiError(500, "internal_error", "SHORT_DOMAIN is not configured")
    return f"https://{domain}/{key}"


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------


def create_link(event: dict) -> dict:
    body = _request_body(event)
    url = normalize_url(body.get("url"))

    created_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    created_by = _caller(event)

    key, existed = resolve_key(
        url,
        lookup_target,
        make_store(created_by, created_at),
        max_attempts=int(os.environ.get("MAX_ATTEMPTS", "16")),
    )

    LOG.info(json.dumps({"event": "create_link", "key": key, "existing": existed}))

    return _response(
        200 if existed else 201,
        {
            "key": key,
            "short_url": _short_url(key),
            "target_url": url,
            "created_at": created_at,
            "existing": existed,
        },
    )


def get_link(key: str) -> dict:
    if not KEY_PATTERN.match(key):
        raise ApiError(
            400,
            "invalid_key",
            "key must be 10 lowercase hex digits, or 8 for a legacy key",
        )

    head = head_metadata(key)
    if head is None or not head.get("WebsiteRedirectLocation"):
        raise ApiError(404, "not_found", "no such key")

    meta = head.get("Metadata") or {}
    created_at = meta.get("created-at")
    if not created_at and head.get("LastModified"):
        created_at = head["LastModified"].strftime("%Y-%m-%dT%H:%M:%SZ")

    return _response(
        200,
        {
            "key": key,
            "short_url": _short_url(key),
            "target_url": head["WebsiteRedirectLocation"],
            "created_at": created_at,
            "created_by": meta.get("created-by"),
        },
    )


def _route(event: dict) -> dict:
    http = (event.get("requestContext") or {}).get("http", {})
    method = (http.get("method") or "").upper()
    path = event.get("rawPath") or http.get("path") or ""
    if len(path) > 1:
        path = path.rstrip("/")

    if path == "/api/links" and method == "POST":
        return create_link(event)

    match = LINK_PATH.match(path)
    if match and method == "GET":
        return get_link(match.group(1))

    if path == "/api/links" or match:
        raise ApiError(405, "method_not_allowed", f"{method} is not supported here")

    raise ApiError(404, "not_found", "unknown path")


def lambda_handler(event, context):  # noqa: ARG001
    try:
        return _route(event)
    except ApiError as exc:
        if exc.status >= 500:
            LOG.error("%s: %s", exc.code, exc.message)
        return _response(exc.status, {"error": exc.code, "message": exc.message})
    except Exception:  # noqa: BLE001
        LOG.exception("unhandled error")
        return _response(
            500, {"error": "internal_error", "message": "internal server error"}
        )
