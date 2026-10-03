#!/usr/bin/env bash
# =============================================================================
#  End-to-end verification of the ModSecurity WAF (lab variant 4).
#
#  Checks, through the WAF on http://localhost:8080 :
#    * normal browsers still get through (no false positives);
#    * known vulnerability scanners / botnets are blocked by the custom rule;
#    * classic web attacks are blocked by the OWASP Core Rule Set.
#  The L7-DDoS / static-resource rate limit is verified separately by
#  ddos_static.py (it needs a burst of requests).
#
#  Usage: ./run-tests.sh [base-url]
# =============================================================================
set -u

BASE="${1:-http://localhost:8080}"
CHROME="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

pass=0
fail=0

code() { curl -sk -o /dev/null -w "%{http_code}" "$@"; }

check() { # description expected actual
    if [ "$2" = "$3" ]; then
        printf '  [PASS] %-55s -> HTTP %s\n' "$1" "$3"
        pass=$((pass + 1))
    else
        printf '  [FAIL] %-55s -> HTTP %s (expected %s)\n' "$1" "$3" "$2"
        fail=$((fail + 1))
    fi
}

echo "== 1. Legitimate traffic must NOT be blocked =="
check "Chrome request"           200 "$(code -A "$CHROME" "$BASE/")"
check "Firefox request"          200 "$(code -A 'Mozilla/5.0 (Windows NT 10.0) Gecko/20100101 Firefox/121.0' "$BASE/")"
check "curl default UA"          200 "$(code "$BASE/")"
check "static asset (favicon)"   200 "$(code -A "$CHROME" "$BASE/favicon.ico")"
check "JSON API"                 200 "$(code -A "$CHROME" "$BASE/api/news")"

echo
echo "== 2. Custom rule 1000001: scanners / botnets by User-Agent (expect 403) =="
for ua in \
    "sqlmap/1.7.2#stable (http://sqlmap.org)" \
    "Mozilla/5.00 (Nikto/2.1.6) (Evasions:None)" \
    "masscan/1.3 (https://github.com/robertdavidgraham/masscan)" \
    "zgrab/0.x" \
    "ZmEu" \
    "WPScan v3.8.22 (https://wpscan.com/wordpress-security-scanner)" \
    "Nuclei - Open-source project (github.com/projectdiscovery/nuclei)" \
    "Mozilla/5.0 (compatible; Nmap Scripting Engine; https://nmap.org/book/nse.html)" \
    "Morfeus Fucking Scanner" \
    ; do
    check "UA: $ua" 403 "$(code -A "$ua" "$BASE/")"
done

echo
echo "== 3. OWASP Core Rule Set: classic attacks (expect 403) =="
check "SQL injection"     403 "$(code -A "$CHROME" "$BASE/?id=1%27%20OR%20%271%27%3D%271")"
check "XSS"               403 "$(code -A "$CHROME" "$BASE/?q=<script>alert(1)</script>")"
check "Path traversal"    403 "$(code -A "$CHROME" "$BASE/?file=../../etc/passwd")"
check "Command injection"  403 "$(code -A "$CHROME" "$BASE/?cmd=;cat%20/etc/passwd")"

echo
echo "== 4. L7 DDoS: static-resource rate limit (nginx limit_req -> 429) =="
echo "  (run separately: python3 waf/tests/ddos_static.py)"

echo
echo "-----------------------------------------------------------------"
echo "Summary: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
