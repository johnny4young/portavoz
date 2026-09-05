#!/usr/bin/env python3
"""Serve deterministic loopback-only web evidence for Apuntador tests."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import signal
import socket
import sys
import tempfile
import threading
import time
from contextlib import contextmanager
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Iterable, Iterator


SCHEMA_VERSION = 1
FIXTURE_KIND = "apuntador-local-web-fixture"
GENERATION = "public-local-v1"
CONTENT_SOURCE = "public-synthetic-only"
BIND_HOST = "127.0.0.1"
CANONICAL_FIXTURE_SHA256 = (
    "97a560b3049bd0d2e0b41fc2e8f7664272f7d20fcf4771b6ec7940295822fd26"
)
BEHAVIORS = {
    "document",
    "redirect",
    "slow",
    "partial",
    "error",
    "hostile",
    "disconnect",
}
FRESHNESS = {"fresh", "stale", "missing", "notApplicable"}
TRUST = {"trusted", "untrusted"}
SAFE_ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,79}$")
SAFE_PATH = re.compile(r"^/[a-z0-9][a-z0-9/_-]{0,159}$")


class ApuntadorWebFixtureError(ValueError):
    """Fail-closed web fixture error."""


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ApuntadorWebFixtureError(f"duplicate key: {key}")
        result[key] = value
    return result


def load_json(path: Path | str, maximum_bytes: int = 1_000_000) -> Any:
    source = Path(path)
    try:
        if not source.is_file():
            raise ApuntadorWebFixtureError(f"fixture not found: {source}")
        if source.stat().st_size > maximum_bytes:
            raise ApuntadorWebFixtureError("fixture exceeds the size limit")
        return json.loads(
            source.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except OSError as error:
        raise ApuntadorWebFixtureError("fixture could not be read") from error
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ApuntadorWebFixtureError(
            "fixture is not valid UTF-8 JSON"
        ) from error


def object_shape(value: Any, path: str, required: Iterable[str]) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ApuntadorWebFixtureError(f"{path} must be an object")
    required_keys = set(required)
    missing = required_keys - value.keys()
    extra = value.keys() - required_keys
    if missing:
        raise ApuntadorWebFixtureError(
            f"{path} is missing keys: {', '.join(sorted(missing))}"
        )
    if extra:
        raise ApuntadorWebFixtureError(
            f"{path} contains forbidden keys: {', '.join(sorted(extra))}"
        )
    return value


def enum_value(value: Any, path: str, allowed: set[str]) -> str:
    if not isinstance(value, str) or value not in allowed:
        raise ApuntadorWebFixtureError(
            f"{path} must be one of: {', '.join(sorted(allowed))}"
        )
    return value


def safe_string(value: Any, path: str, pattern: re.Pattern[str]) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise ApuntadorWebFixtureError(f"{path} has an unsafe value")
    return value


def bounded_text(value: Any, path: str, maximum: int) -> str:
    if not isinstance(value, str):
        raise ApuntadorWebFixtureError(f"{path} must be text")
    if len(value) > maximum or "\x00" in value:
        raise ApuntadorWebFixtureError(f"{path} exceeds its safe text boundary")
    return value


def integer(value: Any, path: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ApuntadorWebFixtureError(f"{path} must be an integer")
    if value < minimum or value > maximum:
        raise ApuntadorWebFixtureError(f"{path} is outside its accepted range")
    return value


def validate_fixture(document: Any) -> dict[str, Any]:
    root = object_shape(
        document,
        "fixture",
        (
            "schemaVersion",
            "kind",
            "generation",
            "bindHost",
            "contentSource",
            "routes",
        ),
    )
    if integer(root["schemaVersion"], "fixture.schemaVersion", 1, 1) != 1:
        raise ApuntadorWebFixtureError("fixture.schemaVersion must be 1")
    if root["kind"] != FIXTURE_KIND:
        raise ApuntadorWebFixtureError(f"fixture.kind must be {FIXTURE_KIND}")
    if root["generation"] != GENERATION:
        raise ApuntadorWebFixtureError(f"fixture.generation must be {GENERATION}")
    if root["bindHost"] != BIND_HOST:
        raise ApuntadorWebFixtureError(
            "fixture.bindHost must remain IPv4 loopback"
        )
    if root["contentSource"] != CONTENT_SOURCE:
        raise ApuntadorWebFixtureError(
            f"fixture.contentSource must be {CONTENT_SOURCE}"
        )
    if not isinstance(root["routes"], list) or not root["routes"]:
        raise ApuntadorWebFixtureError("fixture.routes must be nonempty")
    routes: dict[str, dict[str, Any]] = {}
    ids: set[str] = set()
    behaviors: set[str] = set()
    for index, raw_route in enumerate(root["routes"]):
        path = f"fixture.routes[{index}]"
        route = object_shape(
            raw_route,
            path,
            (
                "id",
                "path",
                "behavior",
                "status",
                "delayMilliseconds",
                "location",
                "freshness",
                "trust",
                "publishedAt",
                "body",
            ),
        )
        route_id = safe_string(route["id"], f"{path}.id", SAFE_ID)
        route_path = safe_string(route["path"], f"{path}.path", SAFE_PATH)
        if route_id in ids:
            raise ApuntadorWebFixtureError(f"duplicate route id: {route_id}")
        if route_path in routes:
            raise ApuntadorWebFixtureError(f"duplicate route path: {route_path}")
        behavior = enum_value(route["behavior"], f"{path}.behavior", BEHAVIORS)
        freshness = enum_value(
            route["freshness"], f"{path}.freshness", FRESHNESS
        )
        trust = enum_value(route["trust"], f"{path}.trust", TRUST)
        delay = integer(
            route["delayMilliseconds"], f"{path}.delayMilliseconds", 0, 2_000
        )
        body = bounded_text(route["body"], f"{path}.body", 20_000)
        status = route["status"]
        location = route["location"]
        published_at = route["publishedAt"]
        if behavior == "disconnect":
            if status is not None or body or location is not None:
                raise ApuntadorWebFixtureError(
                    f"{path} disconnect must not form an HTTP response"
                )
        else:
            status = integer(status, f"{path}.status", 100, 599)
        if behavior == "redirect":
            if status not in {301, 302, 307, 308}:
                raise ApuntadorWebFixtureError(
                    f"{path} redirect must use a redirect status"
                )
            safe_string(location, f"{path}.location", SAFE_PATH)
            if body:
                raise ApuntadorWebFixtureError(
                    f"{path} redirect body must remain empty"
                )
        elif location is not None:
            raise ApuntadorWebFixtureError(
                f"{path} non-redirect must not declare a location"
            )
        if behavior in {"document", "slow", "partial", "hostile"} and status != 200:
            raise ApuntadorWebFixtureError(
                f"{path} content response must use status 200"
            )
        if behavior == "error" and status < 400:
            raise ApuntadorWebFixtureError(
                f"{path} error response must use status 400 or greater"
            )
        if behavior == "slow" and delay < 100:
            raise ApuntadorWebFixtureError(
                f"{path} slow response must be observably delayed"
            )
        if behavior != "slow" and delay != 0:
            raise ApuntadorWebFixtureError(
                f"{path} only the slow route may delay"
            )
        if behavior in {"document", "slow", "partial", "hostile"} and not body:
            raise ApuntadorWebFixtureError(f"{path} must contain a response body")
        if freshness in {"fresh", "stale"}:
            if not isinstance(published_at, str) or not published_at.endswith("Z"):
                raise ApuntadorWebFixtureError(
                    f"{path} freshness requires an observed UTC date"
                )
            try:
                datetime.fromisoformat(
                    published_at.removesuffix("Z") + "+00:00"
                )
            except ValueError as error:
                raise ApuntadorWebFixtureError(
                    f"{path} has an invalid observed UTC date"
                ) from error
            if published_at not in body:
                raise ApuntadorWebFixtureError(
                    f"{path} body must expose its observed publication date"
                )
        elif published_at is not None:
            raise ApuntadorWebFixtureError(
                f"{path} non-dated response must not invent a publication date"
            )
        if behavior == "hostile":
            if trust != "untrusted" or "data-untrusted" not in body:
                raise ApuntadorWebFixtureError(
                    f"{path} hostile content must remain explicitly untrusted"
                )
        if behavior == "disconnect" and trust != "untrusted":
            raise ApuntadorWebFixtureError(
                f"{path} disconnected transport cannot be trusted evidence"
            )
        ids.add(route_id)
        behaviors.add(behavior)
        routes[route_path] = {
            "id": route_id,
            "path": route_path,
            "behavior": behavior,
            "status": status,
            "delayMilliseconds": delay,
            "location": location,
            "freshness": freshness,
            "trust": trust,
            "publishedAt": published_at,
            "body": body,
        }
    missing_behaviors = BEHAVIORS - behaviors
    if missing_behaviors:
        raise ApuntadorWebFixtureError(
            "fixture misses behaviors: " + ", ".join(sorted(missing_behaviors))
        )
    required_routes = {
        "/source/fresh-en",
        "/source/fresh-es",
        "/source/stale-en",
        "/source/stale-es",
        "/source/missing-date",
        "/error/provider-down",
        "/hostile/prompt-injection-en",
        "/hostile/prompt-injection-es",
        "/transport/disconnect",
    }
    missing_routes = required_routes - routes.keys()
    if missing_routes:
        raise ApuntadorWebFixtureError(
            "fixture misses required routes: " + ", ".join(sorted(missing_routes))
        )
    for route in routes.values():
        if (
            route["behavior"] == "redirect"
            and route["location"] not in routes
        ):
            raise ApuntadorWebFixtureError(
                f"{route['path']} redirects to an unknown local route"
            )
        links = re.findall(r'href="(/[a-z0-9/_-]+)"', route["body"])
        unknown_links = sorted(set(links) - routes.keys())
        if unknown_links:
            raise ApuntadorWebFixtureError(
                f"{route['path']} cites an unknown local route: {unknown_links[0]}"
            )
        if route["path"] in {"/source/fresh-en", "/source/fresh-es"} and not links:
            raise ApuntadorWebFixtureError(
                f"{route['path']} must retain a direct local citation"
            )
    return {
        "generation": GENERATION,
        "bindHost": BIND_HOST,
        "routes": routes,
    }


class FixtureHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, fixture: dict[str, Any], port: int = 0):
        self.fixture = fixture
        super().__init__((fixture["bindHost"], port), FixtureRequestHandler)


class FixtureRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "PortavozFixture/1"
    sys_version = ""

    @property
    def fixture_server(self) -> FixtureHTTPServer:
        return self.server  # type: ignore[return-value]

    def do_GET(self) -> None:  # noqa: N802 — BaseHTTPRequestHandler contract
        route = self.fixture_server.fixture["routes"].get(self.path)
        if route is None:
            self._send_complete(
                status=404,
                body=b"not found",
                freshness="notApplicable",
                trust="untrusted",
                published_at=None,
            )
            return
        behavior = route["behavior"]
        if behavior == "disconnect":
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.connection.close()
            self.close_connection = True
            return
        if route["delayMilliseconds"]:
            time.sleep(route["delayMilliseconds"] / 1_000)
        body = route["body"].encode("utf-8")
        if behavior == "redirect":
            self.send_response(route["status"])
            self.send_header("Location", route["location"])
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "no-store")
            self.send_header(
                "X-Portavoz-Fixture-Freshness", route["freshness"]
            )
            self.send_header("X-Portavoz-Fixture-Trust", route["trust"])
            self.end_headers()
            return
        if behavior == "partial":
            self.send_response(route["status"])
            self._send_fixture_headers(route, body)
            self.end_headers()
            split = max(1, len(body) // 2)
            self.wfile.write(body[:split])
            self.wfile.flush()
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.connection.close()
            self.close_connection = True
            return
        self.send_response(route["status"])
        self._send_fixture_headers(route, body)
        if behavior == "error":
            self.send_header("Retry-After", "1")
        self.end_headers()
        self.wfile.write(body)

    def _send_complete(
        self,
        *,
        status: int,
        body: bytes,
        freshness: str,
        trust: str,
        published_at: str | None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Portavoz-Fixture-Freshness", freshness)
        self.send_header("X-Portavoz-Fixture-Trust", trust)
        if published_at is not None:
            self.send_header("X-Portavoz-Fixture-Published-At", published_at)
        self.end_headers()
        self.wfile.write(body)

    def _send_fixture_headers(self, route: dict[str, Any], body: bytes) -> None:
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("ETag", '"' + hashlib.sha256(body).hexdigest() + '"')
        self.send_header(
            "X-Portavoz-Fixture-Freshness", route["freshness"]
        )
        self.send_header("X-Portavoz-Fixture-Trust", route["trust"])
        if route["publishedAt"] is not None:
            self.send_header(
                "X-Portavoz-Fixture-Published-At", route["publishedAt"]
            )

    def log_message(self, format: str, *args: Any) -> None:
        return


@contextmanager
def running_server(
    fixture: dict[str, Any],
) -> Iterator[tuple[FixtureHTTPServer, str]]:
    server = FixtureHTTPServer(fixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address
    try:
        yield server, f"http://{host}:{port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def write_ready_file(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=path.name + ".",
        dir=path.parent,
        text=True,
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, sort_keys=True, allow_nan=False)
            handle.write("\n")
            handle.flush()
            # This is an ephemeral same-host readiness handshake, not durable
            # evidence. Closing before the atomic replace makes the complete
            # descriptor visible without coupling startup to volume sync.
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except OSError:
            pass
        raise


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    verify = commands.add_parser("verify-public")
    verify.add_argument("--fixture", required=True, type=Path)
    serve = commands.add_parser("serve")
    serve.add_argument("--fixture", required=True, type=Path)
    serve.add_argument("--port", type=int, default=0)
    serve.add_argument("--ready-file", type=Path)
    arguments = parser.parse_args(argv)
    try:
        fixture = validate_fixture(load_json(arguments.fixture))
        checksum = hashlib.sha256(arguments.fixture.read_bytes()).hexdigest()
        if arguments.command == "verify-public":
            if checksum != CANONICAL_FIXTURE_SHA256:
                raise ApuntadorWebFixtureError(
                    "public web fixture is not canonical"
                )
            print(
                "Apuntador local web fixture verified: "
                f"{len(fixture['routes'])} routes"
            )
            return 0
        if arguments.port < 0 or arguments.port > 65_535:
            raise ApuntadorWebFixtureError("port is outside 0...65535")
        server = FixtureHTTPServer(fixture, arguments.port)
        host, port = server.server_address
        payload = {
            "schemaVersion": SCHEMA_VERSION,
            "generation": fixture["generation"],
            "fixtureChecksum": checksum,
            "baseURL": f"http://{host}:{port}",
            "processID": os.getpid(),
        }
        if arguments.ready_file is not None:
            write_ready_file(arguments.ready_file, payload)
        print(json.dumps(payload, sort_keys=True, allow_nan=False), flush=True)

        def stop_server(_signal: int, _frame: Any) -> None:
            threading.Thread(target=server.shutdown, daemon=True).start()

        signal.signal(signal.SIGTERM, stop_server)
        signal.signal(signal.SIGINT, stop_server)
        try:
            server.serve_forever()
        finally:
            server.server_close()
        return 0
    except (ApuntadorWebFixtureError, OSError) as error:
        print(f"Apuntador web fixture failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
