"""Unit tests for handler.py.

    cd functions/api && python3 -m unittest -v

No dependencies beyond the standard library: handler.py imports boto3 lazily,
so these run without the AWS SDK installed. No network access either -- the S3
client is replaced with a fake.
"""

import hashlib
import os
import unittest

import handler
from handler import ApiError, compute_key, key_material, normalize_url, resolve_key


class NormalizeUrlTest(unittest.TestCase):
    def test_keeps_a_plain_url_intact(self):
        url = "https://example.com/a/b?x=1&y=2#frag"
        self.assertEqual(normalize_url(url), url)

    def test_trims_surrounding_whitespace(self):
        self.assertEqual(
            normalize_url("  https://example.com/  "), "https://example.com/"
        )

    def test_lowercases_scheme_and_host_only(self):
        self.assertEqual(
            normalize_url("HTTPS://Example.COM/Path?A=B"),
            "https://example.com/Path?A=B",
        )

    def test_drops_default_ports(self):
        self.assertEqual(normalize_url("https://example.com:443/"), "https://example.com/")
        self.assertEqual(normalize_url("http://example.com:80/"), "http://example.com/")

    def test_keeps_non_default_ports(self):
        self.assertEqual(
            normalize_url("https://example.com:8443/x"), "https://example.com:8443/x"
        )

    def test_adds_missing_root_path(self):
        self.assertEqual(normalize_url("https://example.com"), "https://example.com/")

    def test_preserves_query_order_and_duplicates(self):
        url = "https://example.com/?b=2&a=1&b=3&utm_source=x"
        self.assertEqual(normalize_url(url), url)

    def test_brackets_ipv6_literals(self):
        self.assertEqual(
            normalize_url("https://[2606:4700:4700::1111]/x"),
            "https://[2606:4700:4700::1111]/x",
        )

    def _assert_rejected(self, url, fragment=""):
        with self.assertRaises(ApiError) as ctx:
            normalize_url(url)
        self.assertEqual(ctx.exception.status, 400)
        if fragment:
            self.assertIn(fragment, ctx.exception.message)

    def test_rejects_dangerous_schemes(self):
        for url in (
            "javascript:alert(1)",
            "data:text/html;base64,PHNjcmlwdD4=",
            "file:///etc/passwd",
            "ftp://example.com/x",
        ):
            with self.subTest(url=url):
                self._assert_rejected(url)

    def test_rejects_embedded_credentials(self):
        self._assert_rejected("https://trusted.com@evil.example/", "credentials")

    def test_rejects_loopback_and_private_hosts(self):
        for url in (
            "http://localhost/",
            "http://app.localhost/",
            "http://127.0.0.1/",
            "http://10.0.0.1/",
            "http://192.168.1.1/",
            "http://172.16.0.1/",
            "http://169.254.169.254/latest/meta-data/",
            "http://[::1]/",
        ):
            with self.subTest(url=url):
                self._assert_rejected(url)

    def test_rejects_empty_and_hostless(self):
        self._assert_rejected("")
        self._assert_rejected("   ")
        self._assert_rejected("https:///path")

    def test_rejects_overlong_url(self):
        self._assert_rejected("https://example.com/" + "a" * 2100)

    def test_rejects_non_string(self):
        for value in (None, 123, ["https://example.com"]):
            with self.subTest(value=value):
                with self.assertRaises(ApiError):
                    normalize_url(value)


class KeyDerivationTest(unittest.TestCase):
    def test_is_a_fixed_vector(self):
        """Pin the derivation.

        Not a compatibility guarantee -- reproducing the CRC32 keys this
        replaced is explicitly not a goal. It is here so that a change to the
        hash, the truncation width or the encoding has to be made on purpose.
        """
        url = (
            "https://notes.example.com/shard/s1/sh/00000000-0000-4000-8000-"
            "000000000000/ExampleShareTokenNotARealOne_A"
        )
        self.assertEqual(compute_key(url), "cb334b9fa4")

    def test_key_shape(self):
        for url in ("https://a.example/", "https://b.example/x?y=1"):
            with self.subTest(url=url):
                key = compute_key(url)
                self.assertRegex(key, r"^[0-9a-f]{10}$")

    def test_is_deterministic(self):
        url = "https://example.com/x"
        self.assertEqual(compute_key(url), compute_key(url))

    def test_attempt_zero_hashes_the_bare_url(self):
        url = "https://example.com/x"
        expected = hashlib.sha256(url.encode()).digest()[: handler.KEY_BYTES].hex()
        self.assertEqual(compute_key(url, 0), expected)

    def test_later_attempts_differ(self):
        url = "https://example.com/x"
        keys = {compute_key(url, n) for n in range(8)}
        self.assertEqual(len(keys), 8)

    def test_fragment_cannot_impersonate_a_retry(self):
        """`url#1` at attempt 0 must not collide with `url` at attempt 1."""
        base = "https://example.com/x"
        self.assertNotEqual(
            key_material(base + "#1", 0),
            key_material(base, 1),
        )


class FakeStore:
    """In-memory stand-in for the S3 object store."""

    def __init__(self, initial=None):
        self.objects = dict(initial or {})
        self.writes = 0

    def lookup(self, key):
        return self.objects.get(key)

    def store(self, key, url):
        self.writes += 1
        if key in self.objects:
            return False  # conditional write lost
        self.objects[key] = url
        return True


class ResolveKeyTest(unittest.TestCase):
    def test_stores_a_new_url(self):
        s = FakeStore()
        url = "https://example.com/new"
        key, existed = resolve_key(url, s.lookup, s.store)
        self.assertFalse(existed)
        self.assertEqual(key, compute_key(url))
        self.assertEqual(s.objects[key], url)

    def test_is_idempotent(self):
        s = FakeStore()
        url = "https://example.com/same"
        first, existed_first = resolve_key(url, s.lookup, s.store)
        second, existed_second = resolve_key(url, s.lookup, s.store)
        self.assertEqual(first, second)
        self.assertFalse(existed_first)
        self.assertTrue(existed_second)
        self.assertEqual(s.writes, 1, "must not rewrite an identical registration")

    def test_walks_past_a_genuine_collision(self):
        url = "https://example.com/wants-slot"
        taken = compute_key(url, 0)
        s = FakeStore({taken: "https://someone.example/else"})

        key, existed = resolve_key(url, s.lookup, s.store)

        self.assertFalse(existed)
        self.assertEqual(key, compute_key(url, 1))
        self.assertEqual(s.objects[taken], "https://someone.example/else")

    def test_walks_past_several_collisions(self):
        url = "https://example.com/crowded"
        occupied = {compute_key(url, n): f"https://other{n}.example/" for n in range(5)}
        s = FakeStore(occupied)

        key, _ = resolve_key(url, s.lookup, s.store)

        self.assertEqual(key, compute_key(url, 5))

    def test_target_is_never_mutated_by_collision_handling(self):
        """The stored redirect must stay byte-identical to the input URL."""
        url = "https://example.com/exact?a=1"
        s = FakeStore({compute_key(url, 0): "https://other.example/"})
        key, _ = resolve_key(url, s.lookup, s.store)
        self.assertEqual(s.objects[key], url)

    def test_gives_up_after_max_attempts(self):
        url = "https://example.com/hopeless"
        s = FakeStore({compute_key(url, n): f"https://o{n}.example/" for n in range(16)})
        with self.assertRaises(ApiError) as ctx:
            resolve_key(url, s.lookup, s.store, max_attempts=16)
        self.assertEqual(ctx.exception.status, 409)
        self.assertEqual(ctx.exception.code, "collision_exhausted")

    def test_race_where_someone_registered_the_same_url(self):
        url = "https://example.com/raced"
        key = compute_key(url)
        s = FakeStore()

        def store_that_loses(k, u):
            s.objects[k] = url  # another writer got there first, with our URL
            return False

        got, existed = resolve_key(url, s.lookup, store_that_loses)
        self.assertEqual(got, key)
        self.assertTrue(existed)

    def test_race_where_someone_registered_a_different_url(self):
        url = "https://example.com/raced-other"
        first_key = compute_key(url, 0)
        s = FakeStore()
        lost = {"done": False}

        def store_once_then_succeed(k, u):
            if not lost["done"]:
                lost["done"] = True
                s.objects[k] = "https://squatter.example/"
                return False
            s.objects[k] = u
            return True

        got, existed = resolve_key(url, s.lookup, store_once_then_succeed)
        self.assertFalse(existed)
        self.assertNotEqual(got, first_key)
        self.assertEqual(got, compute_key(url, 1))

    def test_skips_objects_without_a_redirect_target(self):
        """A stray non-redirect object must not be overwritten."""
        url = "https://example.com/stray"
        stray_key = compute_key(url, 0)
        s = FakeStore()
        s.objects[stray_key] = None  # exists, but no redirect metadata

        def store(k, u):
            if k in s.objects:
                return False
            s.objects[k] = u
            return True

        key, existed = resolve_key(url, s.lookup, store)
        self.assertFalse(existed)
        self.assertNotEqual(key, stray_key)
        self.assertIsNone(s.objects[stray_key])


class FakeS3:
    """Minimal stand-in for the boto3 S3 client."""

    def __init__(self, objects=None):
        self.objects = dict(objects or {})
        self.puts = []

    def head_object(self, Bucket, Key):  # noqa: N803
        if Key not in self.objects:
            raise handler.ClientError(
                {"Error": {"Code": "404", "Message": "Not Found"}}, "HeadObject"
            )
        return self.objects[Key]

    def put_object(self, **kwargs):
        key = kwargs["Key"]
        if kwargs.get("IfNoneMatch") == "*" and key in self.objects:
            raise handler.ClientError(
                {"Error": {"Code": "PreconditionFailed"}}, "PutObject"
            )
        self.puts.append(kwargs)
        self.objects[key] = {
            "WebsiteRedirectLocation": kwargs.get("WebsiteRedirectLocation"),
            "Metadata": kwargs.get("Metadata", {}),
        }
        return {}


class S3AdapterTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeS3()
        handler._s3 = self.fake
        os.environ["BUCKET"] = "test-bucket"
        os.environ["SHORT_DOMAIN"] = "short.example.net"

    def tearDown(self):
        handler._s3 = None
        os.environ.pop("BUCKET", None)
        os.environ.pop("SHORT_DOMAIN", None)

    def test_lookup_returns_none_for_missing_key(self):
        self.assertIsNone(handler.lookup_target("deadbeef"))

    def test_lookup_returns_the_redirect_target(self):
        self.fake.objects["deadbeef"] = {
            "WebsiteRedirectLocation": "https://example.com/x"
        }
        self.assertEqual(handler.lookup_target("deadbeef"), "https://example.com/x")

    def test_lookup_propagates_unexpected_errors(self):
        def boom(**_kwargs):
            raise handler.ClientError({"Error": {"Code": "InternalError"}}, "HeadObject")

        self.fake.head_object = boom
        with self.assertRaises(handler.ClientError):
            handler.lookup_target("deadbeef")

    def test_denial_explains_the_listbucket_requirement(self):
        """A 403 here usually means s3:ListBucket is missing, not GetObject.

        S3 reports a missing key as 403 when the caller cannot list the bucket,
        so the raw error points at the wrong permission.
        """
        for code in ("403", "AccessDenied", "Forbidden"):
            with self.subTest(code=code):
                def boom(**_kwargs):
                    raise handler.ClientError({"Error": {"Code": code}}, "HeadObject")

                self.fake.head_object = boom
                with self.assertRaises(ApiError) as ctx:
                    handler.lookup_target("deadbeef")
                self.assertEqual(ctx.exception.status, 500)
                self.assertIn("s3:ListBucket", ctx.exception.message)

    def test_denial_is_not_mistaken_for_a_free_key(self):
        """A denial must never look like 'this key is available'.

        Otherwise collision resolution would happily overwrite someone's link.
        """
        def boom(**_kwargs):
            raise handler.ClientError({"Error": {"Code": "403"}}, "HeadObject")

        self.fake.head_object = boom
        with self.assertRaises(ApiError):
            handler.lookup_target("deadbeef")
        self.assertEqual(self.fake.puts, [], "must not write after a denied probe")

    def test_store_writes_expected_object_shape(self):
        store = handler.make_store("tester", "2026-08-02T00:00:00Z")
        self.assertTrue(store("deadbeef", "https://example.com/x"))

        put = self.fake.puts[0]
        self.assertEqual(put["Body"], b"")
        self.assertEqual(put["WebsiteRedirectLocation"], "https://example.com/x")
        self.assertEqual(put["IfNoneMatch"], "*", "must be a conditional write")
        self.assertEqual(put["Metadata"]["created-by"], "tester")

    def test_store_reports_a_lost_race_instead_of_raising(self):
        self.fake.objects["deadbeef"] = {"WebsiteRedirectLocation": "https://other/"}
        store = handler.make_store("tester", "2026-08-02T00:00:00Z")
        self.assertFalse(store("deadbeef", "https://example.com/x"))

    def test_store_never_overwrites(self):
        self.fake.objects["deadbeef"] = {"WebsiteRedirectLocation": "https://other/"}
        handler.make_store("t", "now")("deadbeef", "https://example.com/x")
        self.assertEqual(
            self.fake.objects["deadbeef"]["WebsiteRedirectLocation"], "https://other/"
        )

    def test_missing_bucket_config_is_a_500(self):
        os.environ.pop("BUCKET")
        with self.assertRaises(ApiError) as ctx:
            handler.lookup_target("deadbeef")
        self.assertEqual(ctx.exception.status, 500)


class EndToEndTest(unittest.TestCase):
    """Exercise lambda_handler against the fake S3 client."""

    def setUp(self):
        self.fake = FakeS3()
        handler._s3 = self.fake
        os.environ["BUCKET"] = "test-bucket"
        os.environ["SHORT_DOMAIN"] = "short.example.net"

    def tearDown(self):
        handler._s3 = None
        os.environ.pop("BUCKET", None)
        os.environ.pop("SHORT_DOMAIN", None)

    @staticmethod
    def _post(url):
        import json

        return {
            "rawPath": "/api/links",
            "requestContext": {
                "http": {"method": "POST", "path": "/api/links"},
                "authorizer": {"iam": {"userId": "AIDATEST"}},
            },
            "headers": {"content-type": "application/json"},
            "body": json.dumps({"url": url}),
        }

    def _body(self, result):
        import json

        return json.loads(result["body"])

    def test_register_then_fetch(self):
        result = handler.lambda_handler(self._post("https://example.com/a?b=1"), None)
        self.assertEqual(result["statusCode"], 201)
        created = self._body(result)
        self.assertEqual(created["target_url"], "https://example.com/a?b=1")
        self.assertEqual(created["short_url"], f"https://short.example.net/{created['key']}")
        self.assertFalse(created["existing"])

        fetched = handler.lambda_handler(
            {
                "rawPath": f"/api/links/{created['key']}",
                "requestContext": {"http": {"method": "GET"}},
            },
            None,
        )
        self.assertEqual(fetched["statusCode"], 200)
        self.assertEqual(self._body(fetched)["target_url"], "https://example.com/a?b=1")

    def test_second_registration_is_idempotent(self):
        first = self._body(handler.lambda_handler(self._post("https://example.com/dup"), None))
        second_result = handler.lambda_handler(self._post("https://example.com/dup"), None)
        second = self._body(second_result)

        self.assertEqual(second_result["statusCode"], 200)
        self.assertTrue(second["existing"])
        self.assertEqual(first["key"], second["key"])
        self.assertEqual(len(self.fake.puts), 1)

    def test_normalisation_applies_before_hashing(self):
        a = self._body(handler.lambda_handler(self._post("HTTPS://Example.COM:443/x"), None))
        b = self._body(handler.lambda_handler(self._post("https://example.com/x"), None))
        self.assertEqual(a["key"], b["key"])
        self.assertEqual(a["target_url"], "https://example.com/x")

    def test_records_the_caller(self):
        created = self._body(handler.lambda_handler(self._post("https://example.com/who"), None))
        stored = self.fake.objects[created["key"]]
        self.assertEqual(stored["Metadata"]["created-by"], "AIDATEST")

    def test_unknown_key_is_404(self):
        result = handler.lambda_handler(
            {
                "rawPath": "/api/links/0000000000",
                "requestContext": {"http": {"method": "GET"}},
            },
            None,
        )
        self.assertEqual(result["statusCode"], 404)

    def test_legacy_eight_digit_keys_still_resolve(self):
        """CRC32-era links are printed on things. Lookups must keep working."""
        self.fake.objects["4103d7b4"] = {
            "WebsiteRedirectLocation": "https://example.com/shortened-long-ago",
            "Metadata": {"created-at": "2026-01-01T00:00:00Z"},
        }
        result = handler.lambda_handler(
            {
                "rawPath": "/api/links/4103d7b4",
                "requestContext": {"http": {"method": "GET"}},
            },
            None,
        )
        self.assertEqual(result["statusCode"], 200)
        self.assertEqual(
            self._body(result)["target_url"], "https://example.com/shortened-long-ago"
        )

    def test_reshortening_a_legacy_url_mints_a_new_key(self):
        """The accepted cost of the cutover, asserted rather than assumed.

        The old object is left alone and the old short link still redirects;
        what is lost is only that one URL now has two keys.
        """
        legacy = {"WebsiteRedirectLocation": "https://example.com/both", "Metadata": {}}
        self.fake.objects["4103d7b4"] = legacy

        created = self._body(handler.lambda_handler(self._post("https://example.com/both"), None))

        self.assertNotEqual(created["key"], "4103d7b4")
        self.assertEqual(len(created["key"]), 10)
        self.assertIs(self.fake.objects["4103d7b4"], legacy, "old object untouched")

    def test_rejected_url_never_touches_s3(self):
        result = handler.lambda_handler(self._post("javascript:alert(1)"), None)
        self.assertEqual(result["statusCode"], 400)
        self.assertEqual(self.fake.puts, [])


class RoutingTest(unittest.TestCase):
    @staticmethod
    def _event(method, path, body=None):
        return {
            "rawPath": path,
            "requestContext": {"http": {"method": method, "path": path}},
            "headers": {"content-type": "application/json"},
            "body": body,
        }

    def test_unknown_path_is_404(self):
        result = handler.lambda_handler(self._event("GET", "/nope"), None)
        self.assertEqual(result["statusCode"], 404)

    def test_wrong_method_is_405(self):
        result = handler.lambda_handler(self._event("DELETE", "/api/links"), None)
        self.assertEqual(result["statusCode"], 405)

    def test_missing_body_is_400(self):
        result = handler.lambda_handler(self._event("POST", "/api/links"), None)
        self.assertEqual(result["statusCode"], 400)

    def test_non_json_content_type_is_415(self):
        event = self._event("POST", "/api/links", body='{"url":"https://example.com/"}')
        event["headers"] = {"content-type": "text/plain"}
        result = handler.lambda_handler(event, None)
        self.assertEqual(result["statusCode"], 415)

    def test_malformed_key_is_400(self):
        result = handler.lambda_handler(self._event("GET", "/api/links/NOTAKEY"), None)
        self.assertEqual(result["statusCode"], 400)

    def test_only_the_two_valid_key_lengths_are_accepted(self):
        """Guards the alternation group in KEY_PATTERN.

        Written without the group -- ^[0-9a-f]{8}|[0-9a-f]{10}$ -- the anchors
        bind to one branch each, and a nine-digit key would match the first.
        """
        for key in ("1a2b3c4", "1a2b3c4d5", "1a2b3c4d5e6", "1a2b3c4d5e6f"):
            with self.subTest(key=key):
                result = handler.lambda_handler(
                    self._event("GET", f"/api/links/{key}"), None
                )
                self.assertEqual(result["statusCode"], 400)

    def test_trailing_slash_is_tolerated(self):
        result = handler.lambda_handler(self._event("POST", "/api/links/"), None)
        self.assertEqual(result["statusCode"], 400, "should route, then fail on body")

    def test_errors_are_json(self):
        result = handler.lambda_handler(self._event("GET", "/nope"), None)
        self.assertIn("application/json", result["headers"]["content-type"])
        self.assertIn("error", result["body"])


if __name__ == "__main__":
    unittest.main()
