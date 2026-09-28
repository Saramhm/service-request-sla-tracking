#!/usr/bin/env bash
# End-to-end checks against the running stack:
#   1. SQL unit tests (each runs in a transaction that is rolled back)
#   2. Every n8n webhook over HTTP, including the unhappy paths
# The one request it creates is cancelled at the end so the queue stays clean.
#
#   ./scripts/smoke-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1

DB_USER=$(grep '^POSTGRES_USER=' .env | cut -d= -f2)
N8N=http://localhost:5678/webhook
failures=0

for t in db/tests/*.sql; do
  if docker compose exec -T postgres psql -U "$DB_USER" -d servicedesk -v ON_ERROR_STOP=1 -q < "$t" > /dev/null 2>&1; then
    echo "PASS  sql  $t"
  else
    echo "FAIL  sql  $t"; failures=$((failures + 1))
  fi
done

# check <label> <expected status> <method> <path> [json body]  — prints the body to stdout
check() {
  local label=$1 expected=$2 method=$3 path=$4 body=${5:-} res code
  if [ -n "$body" ]; then
    res=$(curl -s -w '\n%{http_code}' -X "$method" "$N8N/$path" -H 'Content-Type: application/json' --data-binary "$body" || true)
  else
    res=$(curl -s -w '\n%{http_code}' -X "$method" "$N8N/$path" || true)
  fi
  code=${res##*$'\n'}
  res=${res%$'\n'*}
  if [ "$code" = "$expected" ]; then
    echo "PASS  http $label ($code)" >&2
  else
    echo "FAIL  http $label: expected $expected, got $code: ${res:0:300}" >&2; failures=$((failures + 1))
  fi
  printf '%s' "$res"
}
field() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s)[process.argv[1]] ?? "")}catch{console.log("")}})' "$1"; }

stamp=$(date +%s)
key=$(node -e 'console.log(require("crypto").randomUUID())')
req='{"requester_name":"Smoke Test","requester_email":"smoke.test@example.test","department":"IT","request_type":"OTHER",
      "title":"Smoke test '"$stamp"' needs access to the finance dashboard","description":"Automated end-to-end check of the intake workflow.",
      "declared_priority":"P3","idempotency_key":"'"$key"'"}'

id=$(check "submit: created"                201 POST service-request "$req" | field request_id)
[ -n "$id" ] || { echo "FAIL  http submit: no request_id returned"; failures=$((failures + 1)); }
check "submit: same key replays"            200 POST service-request "$req" > /dev/null
check "submit: duplicate title"             409 POST service-request "${req/$key/$(node -e 'console.log(require("crypto").randomUUID())')}" > /dev/null
check "submit: invalid fields"              422 POST service-request '{"requester_email":"nope","title":"x"}' > /dev/null
check "submit: P1 without justification"    422 POST service-request "${req/\"P3\"/\"P1\"}" > /dev/null
check "queue: filters"                      200 GET  "requests?status=OPEN&department=IT&sla=ALL" > /dev/null
check "update: unknown request"             404 POST requests/update '{"request_id":"REQ-1999-000001","status":"RESOLVED"}' > /dev/null
check "update: unknown status"              422 POST requests/update '{"request_id":"'"$id"'","status":"DONE"}' > /dev/null
check "update: cancel the smoke request"    200 POST requests/update '{"request_id":"'"$id"'","status":"CANCELLED","actor":"smoke-test","note":"Automated test"}' > /dev/null
check "report: last 7 days"                 200 GET  "reports/sla?days=7" > /dev/null

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"; exit 1
fi
echo "All checks passed (test request $id was created and cancelled)."
