#!/bin/sh
# Report how much life is left in the Developer ID signing certificate.
#
# Renewal is manual — Apple issues Developer ID certificates through Xcode or
# the developer portal, with no API to automate — so the job of this script is
# to make sure nobody has to remember the date. It prints a machine-readable
# summary and exits non-zero once the certificate is expired.
#
# Usage: check-signing-certificate.sh <keychain-path> [warning-days]
set -eu

KEYCHAIN="${1:-}"
WARNING_DAYS="${2:-90}"
[ -n "$KEYCHAIN" ] || { echo "usage: $0 <keychain-path> [warning-days]" >&2; exit 2; }

PEM="$(security find-certificate -c "Developer ID Application" -p "$KEYCHAIN" 2>/dev/null || true)"
[ -n "$PEM" ] || { echo "error: no Developer ID Application certificate in $KEYCHAIN" >&2; exit 2; }

NOT_AFTER="$(printf '%s\n' "$PEM" | openssl x509 -noout -enddate | cut -d= -f2)"
# openssl prints "Feb  1 22:12:15 2027 GMT", padding single-digit days, which is
# what %e consumes.
EXPIRES_AT="$(date -j -f "%b %e %H:%M:%S %Y %Z" "$NOT_AFTER" "+%s")"
DAYS_LEFT=$(( (EXPIRES_AT - $(date "+%s")) / 86400 ))

SUBJECT="$(printf '%s\n' "$PEM" | openssl x509 -noout -subject)"
ISSUER="$(printf '%s\n' "$PEM" | openssl x509 -noout -issuer | sed -n 's/.*CN=\([^,]*\).*/\1/p')"

echo "not_after=$NOT_AFTER"
echo "days_left=$DAYS_LEFT"
echo "issuer=$ISSUER"
echo "subject=$SUBJECT"

if [ "$DAYS_LEFT" -lt 0 ]; then
  echo "status=expired"
  exit 1
fi
if [ "$DAYS_LEFT" -lt "$WARNING_DAYS" ]; then
  echo "status=expiring"
else
  echo "status=ok"
fi
