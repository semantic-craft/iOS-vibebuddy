#!/usr/bin/env python3
"""Provision the local ingest-only credential or send one JSON receipt. Never prints secrets."""
import argparse
import json
import ipaddress
import os
from pathlib import Path
import secrets
import urllib.parse
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("enable", "status", "send"))
    parser.add_argument("--directory", type=Path, default=Path.home() / "Library/Application Support/vibebuddy")
    parser.add_argument("--file", type=Path)
    parser.add_argument("--url", default="http://127.0.0.1:9876/grok-bot/result")
    args = parser.parse_args()
    token_path = args.directory / "grok-bot-result-token"
    if args.action == "enable":
        args.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            fd = os.open(token_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            print("Already provisioned; token was not changed.")
        else:
            with os.fdopen(fd, "w") as target:
                target.write(secrets.token_hex(32))
            print("Provisioned. Restart VibeBuddy to enable automatic Grok Bot message reading and result intake.")
    elif args.action == "status":
        inbox = args.directory / "grok-bot-results"
        print(json.dumps({"provisioned": token_path.is_file(), "receipts": len(list(inbox.glob("*.json")))}))
    else:
        if not args.file:
            parser.error("send requires --file")
        destination = urllib.parse.urlparse(args.url)
        if destination.scheme not in ("http", "https") or destination.username or destination.password or destination.query:
            parser.error("Use an HTTP(S) receiver URL without credentials or query parameters")
        if destination.scheme == "http":
            try:
                address = ipaddress.ip_address(destination.hostname)
                private_transport = address.is_loopback or address in ipaddress.ip_network("100.64.0.0/10")
            except ValueError:
                private_transport = destination.hostname == "localhost"
            if not private_transport:
                parser.error("Plain HTTP requires loopback or a Tailscale address; otherwise use HTTPS")
        if token_path.stat().st_mode & 0o077:
            parser.error("Token file must be owner-only")
        payload = args.file.read_bytes()
        if len(payload) > 65_536:
            parser.error("Receipt exceeds 64 KiB")
        expected_id = json.loads(payload)["id"]
        request = urllib.request.Request(args.url, payload, headers={"Authorization": "Bearer " + token_path.read_text().strip(), "Content-Type": "application/json"})
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        with opener.open(request, timeout=15) as response:
            receipt = json.load(response)
        if receipt.get("id") != expected_id or receipt.get("accepted") is not True:
            raise SystemExit("Receiver did not acknowledge this result")
        print(json.dumps({"accepted": True, "duplicate": receipt.get("duplicate")}))


if __name__ == "__main__":
    main()
