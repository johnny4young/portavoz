import copy
import http.client
import importlib.util
import json
import socket
import stat
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "apuntador_web_fixture", ROOT / "scripts" / "apuntador_web_fixture.py"
)
web_fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(web_fixture)
FIXTURE_PATH = ROOT / "Fixtures" / "ApuntadorWeb" / "public-local-v1.json"


def fixture_document():
    return json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, url):
        return None


class ApuntadorWebFixtureTests(unittest.TestCase):
    def setUp(self):
        self.document = fixture_document()
        self.fixture = web_fixture.validate_fixture(self.document)

    def test_canonical_fixture_covers_every_declared_behavior(self):
        routes = self.fixture["routes"]

        self.assertEqual(len(routes), 14)
        self.assertEqual(
            {route["behavior"] for route in routes.values()},
            web_fixture.BEHAVIORS,
        )
        self.assertEqual(
            web_fixture.hashlib.sha256(FIXTURE_PATH.read_bytes()).hexdigest(),
            web_fixture.CANONICAL_FIXTURE_SHA256,
        )

    def test_server_is_loopback_only_and_keeps_fresh_progress_observable(self):
        with web_fixture.running_server(self.fixture) as (server, base_url):
            self.assertEqual(server.server_address[0], "127.0.0.1")
            for path, phrase in (
                ("/source/fresh-en", "Harbor launches"),
                ("/source/fresh-es", "Costa se lanza"),
            ):
                with self.subTest(path=path):
                    started = time.monotonic()
                    with urllib.request.urlopen(base_url + path, timeout=2) as response:
                        body = response.read().decode("utf-8")
                        self.assertGreaterEqual(time.monotonic() - started, 0.35)
                        self.assertEqual(response.status, 200)
                        self.assertEqual(
                            response.headers["X-Portavoz-Fixture-Freshness"],
                            "fresh",
                        )
                        self.assertEqual(
                            response.headers["X-Portavoz-Fixture-Trust"],
                            "trusted",
                        )
                        self.assertIn(phrase, body)
                        self.assertIn("/authority/release-policy-", body)
                        self.assertTrue(response.headers["ETag"].startswith('"'))

    def test_redirect_and_missing_date_are_explicit(self):
        opener = urllib.request.build_opener(NoRedirect)
        with web_fixture.running_server(self.fixture) as (_, base_url):
            with self.assertRaises(urllib.error.HTTPError) as redirect:
                opener.open(base_url + "/redirect/fresh-en", timeout=2)
            try:
                self.assertEqual(redirect.exception.code, 302)
                self.assertEqual(
                    redirect.exception.headers["Location"],
                    "/source/fresh-en",
                )
                self.assertEqual(
                    redirect.exception.headers["X-Portavoz-Fixture-Freshness"],
                    "notApplicable",
                )
                self.assertEqual(
                    redirect.exception.headers["X-Portavoz-Fixture-Trust"],
                    "trusted",
                )
            finally:
                redirect.exception.close()
            with urllib.request.urlopen(
                base_url + "/source/missing-date", timeout=2
            ) as response:
                self.assertEqual(
                    response.headers["X-Portavoz-Fixture-Freshness"],
                    "missing",
                )
                self.assertIsNone(
                    response.headers["X-Portavoz-Fixture-Published-At"]
                )

    def test_slow_partial_error_and_disconnect_are_deterministic(self):
        with web_fixture.running_server(self.fixture) as (server, base_url):
            started = time.monotonic()
            with urllib.request.urlopen(base_url + "/slow/fresh-es", timeout=2) as response:
                response.read()
            self.assertGreaterEqual(time.monotonic() - started, 0.12)

            host, port = server.server_address
            connection = http.client.HTTPConnection(host, port, timeout=2)
            connection.request("GET", "/partial/fresh-en")
            partial = connection.getresponse()
            with self.assertRaises(http.client.IncompleteRead):
                partial.read()
            connection.close()

            with self.assertRaises(urllib.error.HTTPError) as provider_down:
                urllib.request.urlopen(
                    base_url + "/error/provider-down", timeout=2
                )
            try:
                self.assertEqual(provider_down.exception.code, 503)
                self.assertEqual(
                    provider_down.exception.headers["Retry-After"], "1"
                )
            finally:
                provider_down.exception.close()

            connection = http.client.HTTPConnection(host, port, timeout=2)
            connection.request("GET", "/transport/disconnect")
            with self.assertRaises(http.client.RemoteDisconnected):
                connection.getresponse()
            connection.close()

    def test_offline_is_repeatable_without_an_internet_dependency(self):
        server = web_fixture.FixtureHTTPServer(self.fixture)
        host, port = server.server_address
        server.server_close()

        with self.assertRaises(OSError):
            socket.create_connection((host, port), timeout=0.2)

    def test_hostile_pages_remain_data_and_are_marked_untrusted(self):
        with web_fixture.running_server(self.fixture) as (_, base_url):
            for path, injection in (
                ("/hostile/prompt-injection-en", "IGNORE PREVIOUS INSTRUCTIONS"),
                ("/hostile/prompt-injection-es", "IGNORA LAS INSTRUCCIONES"),
            ):
                with self.subTest(path=path):
                    with urllib.request.urlopen(base_url + path, timeout=2) as response:
                        body = response.read().decode("utf-8")
                        self.assertEqual(
                            response.headers["X-Portavoz-Fixture-Trust"],
                            "untrusted",
                        )
                        self.assertIn('data-untrusted="true"', body)
                        self.assertIn(injection, body)

    def test_validator_rejects_non_loopback_and_unmarked_hostile_content(self):
        public_bind = copy.deepcopy(self.document)
        public_bind["bindHost"] = "0.0.0.0"
        with self.assertRaisesRegex(
            web_fixture.ApuntadorWebFixtureError,
            "must remain IPv4 loopback",
        ):
            web_fixture.validate_fixture(public_bind)

        trusted_hostile = copy.deepcopy(self.document)
        hostile = next(
            route for route in trusted_hostile["routes"]
            if route["behavior"] == "hostile"
        )
        hostile["trust"] = "trusted"
        with self.assertRaisesRegex(
            web_fixture.ApuntadorWebFixtureError,
            "must remain explicitly untrusted",
        ):
            web_fixture.validate_fixture(trusted_hostile)

        broken_citation = copy.deepcopy(self.document)
        fresh = next(
            route for route in broken_citation["routes"]
            if route["id"] == "fresh-en"
        )
        fresh["body"] = fresh["body"].replace(
            "/authority/release-policy-en", "/authority/missing"
        )
        with self.assertRaisesRegex(
            web_fixture.ApuntadorWebFixtureError,
            "cites an unknown local route",
        ):
            web_fixture.validate_fixture(broken_citation)

        broken_redirect = copy.deepcopy(self.document)
        redirect = next(
            route for route in broken_redirect["routes"]
            if route["behavior"] == "redirect"
        )
        redirect["location"] = "/authority/missing"
        with self.assertRaisesRegex(
            web_fixture.ApuntadorWebFixtureError,
            "redirects to an unknown local route",
        ):
            web_fixture.validate_fixture(broken_redirect)

    def test_ready_file_is_atomic_content_free_and_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ready.json"
            first = {
                "schemaVersion": 1,
                "generation": web_fixture.GENERATION,
                "fixtureChecksum": "a" * 64,
                "baseURL": "http://127.0.0.1:1234",
                "processID": 10,
            }
            second = dict(first, processID=11)

            web_fixture.write_ready_file(path, first)
            web_fixture.write_ready_file(path, second)

            self.assertEqual(json.loads(path.read_text()), second)
            self.assertEqual(list(path.parent.glob("ready.json.*")), [])
            self.assertEqual(stat.S_IMODE(path.stat().st_mode) & 0o077, 0)

    def test_unknown_routes_fail_closed_without_reflection(self):
        with web_fixture.running_server(self.fixture) as (_, base_url):
            with self.assertRaises(urllib.error.HTTPError) as missing:
                urllib.request.urlopen(
                    base_url + "/unknown/private-transcript", timeout=2
                )
            try:
                body = missing.exception.read().decode("utf-8")
                self.assertEqual(missing.exception.code, 404)
                self.assertEqual(body, "not found")
                self.assertNotIn("private-transcript", body)
            finally:
                missing.exception.close()


if __name__ == "__main__":
    unittest.main()
