#!/usr/bin/env python3
"""
Application-layer DDoS simulation for the lab (variant 4).

Sends a burst of requests to a *static* resource and reports the HTTP status
codes received. The WAF (nginx `limit_req` zone `static_per_ip`, see
waf/nginx/default.conf.template) should start answering with HTTP 429
(Too Many Requests) once a single source IP exceeds the configured rate
(30 r/s with a burst of 60).

Usage examples:
    python3 ddos_static.py
    python3 ddos_static.py --url http://localhost:8080/favicon.ico --requests 600 --concurrency 50

Exit code: 0 if the WAF rate-limited the burst (429 seen), 1 otherwise.
"""

import argparse
import collections
import concurrent.futures
import ssl
import sys
import urllib.error
import urllib.request

DEFAULT_UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"
)


def build_parser():
    p = argparse.ArgumentParser(description="L7 DDoS simulation against a static resource")
    p.add_argument("--url", default="http://localhost:8080/favicon.ico",
                   help="URL of a static resource to flood")
    p.add_argument("--requests", type=int, default=500, help="total requests to send")
    p.add_argument("--concurrency", type=int, default=50, help="parallel workers")
    p.add_argument("--ua", default=DEFAULT_UA, help="User-Agent header to use")
    p.add_argument("--insecure", action="store_true",
                   help="disable TLS certificate verification (self-signed HTTPS)")
    return p


def main():
    args = build_parser().parse_args()

    def hit(_):
        req = urllib.request.Request(args.url, headers={"User-Agent": args.ua})
        ctx = ssl._create_unverified_context() if args.insecure else None
        try:
            with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
                return resp.status
        except urllib.error.HTTPError as exc:
            return exc.code
        except Exception as exc:  # noqa: BLE001
            return "ERR:%s" % exc

    codes = collections.Counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        for code in pool.map(hit, range(args.requests)):
            codes[code] += 1

    print("Flooding %s with %d requests (%d workers)" % (args.url, args.requests, args.concurrency))
    print("Result summary (HTTP status -> count):")
    for code in sorted(codes, key=lambda c: str(c)):
        print("   %-6s %s" % (code, codes[code]))

    blocked = codes.get(429, 0)
    if blocked:
        print("\n[PASS] WAF rate-limited the source IP: %d requests answered with 429." % blocked)
        return 0
    print("\n[FAIL] No 429 responses were returned; the rate-limit rule did not engage.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
