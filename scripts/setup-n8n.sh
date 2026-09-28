#!/usr/bin/env bash
# Imports the credentials (Postgres, Mailpit SMTP) and every workflow in ./n8n
# into the running n8n container, publishes the workflows and restarts n8n so
# their webhooks and schedules go live. Safe to re-run: fixed IDs make every
# import an upsert.
#
#   docker compose up -d && ./scripts/setup-n8n.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Git Bash on Windows rewrites arguments that look like /paths; keep them as-is.
export MSYS_NO_PATHCONV=1

n8n() { docker compose exec -T n8n "$@"; }

# The credential is built inside the container from the variables compose
# already passes to n8n, so the DB password never touches a file in this repo.
n8n node - <<'JS'
const fs = require('fs');
const env = process.env;
fs.writeFileSync('/tmp/credentials.json', JSON.stringify([{
  id: 'svcDeskPostgres1',
  name: 'Service Desk DB',
  type: 'postgres',
  data: {
    host: env.DB_POSTGRESDB_HOST,
    port: Number(env.DB_POSTGRESDB_PORT),
    database: 'servicedesk',
    user: env.DB_POSTGRESDB_USER,
    password: env.DB_POSTGRESDB_PASSWORD,
    ssl: 'disable',
  },
}, {
  // Mailpit catches all mail locally (http://localhost:8025); no auth, no TLS.
  id: 'svcDeskMailpit01',
  name: 'Mailpit (local SMTP)',
  type: 'smtp',
  data: { host: 'mailpit', port: 1025, secure: false, disableStartTls: true, user: '', password: '' },
}]));
JS
trap 'n8n rm -f /tmp/credentials.json' EXIT
n8n n8n import:credentials --input=/tmp/credentials.json

n8n n8n import:workflow --separate --input=/workflows

# Error workflows run whenever another workflow fails and are never published.
ids=$(n8n node -e '
  const fs = require("fs");
  for (const f of fs.readdirSync("/workflows").filter((f) => f.endsWith(".json"))) {
    const wf = JSON.parse(fs.readFileSync("/workflows/" + f, "utf8"));
    if (!wf.nodes.some((n) => n.type === "n8n-nodes-base.errorTrigger")) console.log(wf.id);
  }
' | tr -d '\r')
for id in $ids; do
  n8n n8n publish:workflow --id="$id"
done

# The CLI writes to the database directly; a running n8n only picks up
# published workflows (and registers their webhooks) on start.
docker compose restart n8n
echo "Waiting for n8n..."
for _ in $(seq 1 60); do
  curl -fsS -o /dev/null http://localhost:5678/healthz 2>/dev/null && break
  sleep 2
done
echo "n8n is up. Webhooks:"
echo "  POST http://localhost:5678/webhook/service-request     submit a request"
echo "  GET  http://localhost:5678/webhook/requests            queue (?status=&department=&sla=)"
echo "  POST http://localhost:5678/webhook/requests/update     change status / assignee"
echo "  GET  http://localhost:5678/webhook/reports/sla         SLA report (?days=30)"
echo "  POST http://localhost:5678/webhook/escalation/run      run the escalation check now"
