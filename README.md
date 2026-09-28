# Service Request Intake & SLA Tracking

This replaces the spreadsheet the Enterprise Analytics & Automation Department uses to track internal requests.

- Employees submit requests in an **Appsmith** form.
- **n8n** validates, classifies and stores each request in **PostgreSQL**, and computes its SLA due date.
- The Automation team works from a live queue with filters, and assigns requests and changes their status there.
- n8n escalates requests that are at risk or breached, and emails a daily SLA report.

```
 Employee ──► Appsmith "Service Desk" (submit form)
                 │  POST /webhook/service-request
                 ▼
 Automation ─► Appsmith "Service Desk - Automation Team" (queue, SLA report)
 team            │  GET /webhook/requests · POST /webhook/requests/update · GET /webhook/reports/sla
                 ▼
               n8n  ── classify, route on the outcome, answer the UI, send email ──► Mailpit (SMTP)
                 │  one SQL function call = one transaction                          ▲
                 ▼                                                                   │
            PostgreSQL  (rules, SLA calendar, audit trail)   n8n schedules: escalation every 15 min,
                                                             SLA report 08:00 on workdays, error alerts
```

**How the work is split:**
- **Appsmith is only the UI.** It holds no database credentials.
- **n8n orchestrates.** It handles input, classification, routing, responses, notifications and schedules.
- **PostgreSQL enforces the business rules.** They live in functions (`submit_request`, `update_request`, `escalate_requests` and others). Each call is one transaction, so a request is either fully processed or not written at all. The functions have SQL tests.

## Quick start

Requirements: Docker Desktop and a bash shell (Git Bash on Windows). Node.js on the host is needed only for `smoke-test.sh`.

1. **Configure:** `cp .env.example .env`, then change the passwords and the encryption key.
2. **Start the stack:** `docker compose up -d`. On first start PostgreSQL runs `db/init/*.sql`, which creates the schema, the reference data and 14 demo requests.
3. **Create the n8n owner:** open http://localhost:5678 and create the owner account.
4. **Load the n8n side:** run `./scripts/setup-n8n.sh`. It imports the two credentials (PostgreSQL and Mailpit) and the six workflows, publishes them, and restarts n8n. You can re-run it safely.
5. **Load the Appsmith side:**
   1. Open http://localhost:8080 and sign up. The first user becomes the admin.
   2. Import the two apps from `appsmith/`: on the workspace, choose **Create new → Import** and pick each JSON file.
   3. The REST datasource `n8n webhooks` (`http://n8n:5678`, no auth) comes with the export.
6. **Optional, fixes the email links:** point notification emails at the imported queue page.
   ```sql
   UPDATE app_settings SET value = '<Request Queue page URL>' WHERE key = 'queue_url';
   ```
7. **Check everything:** `./scripts/smoke-test.sh` runs the SQL tests and exercises every webhook, including the error paths.

| Service | URL | |
|---|---|---|
| Appsmith | http://localhost:8080 | Two apps: **Service Desk** for employees, **Service Desk - Automation Team** for the team |
| n8n | http://localhost:5678 | Workflows and execution history |
| Mailpit | http://localhost:8025 | Every email the system sends is caught here; nothing leaves the machine |
| PostgreSQL | localhost:5432 | Database `servicedesk` holds the app data; database `n8n` holds n8n's own data |

## How the requirements are met

| Requirement | Where |
|---|---|
| Submit form with basic validation | **Service Desk → Submit Request.** Required fields and an email format check. The Justification field appears only for P1. The server validates everything again. |
| Request goes to n8n | `SubmitRequest` API → workflow **Service Request — Submit** |
| Automatic categorisation | n8n node **Classify request** (see [Classification](#classification)) |
| Prevent duplicates (email + normalised title) | `submit_request` + `normalize_title()` + a partial unique index (see [Duplicates and retries](#duplicates-and-retries)) |
| Unique `request_id` like `REQ-2026-001847` | Per-year counter row, updated inside the same transaction, so there are no gaps and no collisions |
| Succeed completely or fail cleanly | One function call is one transaction. Invalid input returns `INVALID` and writes nothing. |
| `due_at` calculated at creation, stored in UTC | `calc_due_at()` (see [SLA rules](#sla-rules)) |
| SLA indicator | `sla_status()`: 🟢 ON TRACK (due in more than 24 h), 🟡 AT RISK (due within 24 h), 🔴 BREACHED (past due). Closed requests show ✅ MET or 🔴 BREACHED. |
| Queue with filters that work together | **Automation Team → Request Queue.** Status, Department and SLA filters are combined with AND on the server. Select a row to assign it or change its status. |
| Escalation | Workflow **SLA — Escalation** (see [Escalation](#escalation)) |
| Reporting | **Automation Team → SLA Report**, plus the workflow **SLA — Reporting**, which emails the report at 08:00 on workdays |

### Webhook API (n8n)

| Method and path | Purpose | Responses |
|---|---|---|
| `POST /webhook/service-request` | Submit a request | `201` created · `200` same `idempotency_key` seen before (replay) · `409` duplicate · `422` invalid · `500` |
| `GET /webhook/requests?status=&department=&sla=` | The queue, most urgent first, with counters | `200` · `500` |
| `POST /webhook/requests/update` | `{request_id, status?, assigned_to?, note?, actor?}` | `200` · `404` · `422` · `500` |
| `GET /webhook/reports/sla?days=30` | SLA report for a period | `200` · `500` |
| `POST /webhook/escalation/run` | Run the escalation check now instead of waiting up to 15 minutes | `200` (runs asynchronously) |

## Design decisions and trade-offs

### Business rules in PostgreSQL, orchestration in n8n
Validation, duplicate detection, ID generation, the SLA calculation and the audit log all run inside one SQL function per operation. That gives real atomicity and makes the rules unit-testable (`db/tests/`). It also means n8n can retry safely.

The trade-off is that the rules are less visible on the n8n canvas. To compensate, every workflow routes on an explicit `outcome` (`CREATED`, `REPLAY`, `DUPLICATE`, `INVALID`, `UPDATED`, `NOT_FOUND`), so each branch is still visible there.

### Duplicates and retries
There are two separate mechanisms:
- **Idempotency.** When a client retries with the same `idempotency_key` (after a double-click or a timeout), it gets the original request back (`REPLAY`, HTTP 200).
- **Business duplicates.** A request with the same email and the same normalised title as an **open** request is rejected with `409`, which names the existing request ID. The attempt is logged as a `DUPLICATE_BLOCKED` event.
  - Normalisation lowercases the title, removes punctuation, collapses spaces and unifies Arabic and Persian ی/ک.
  - A resolved or cancelled request does not block a new one, because the same need can legitimately come back.
  - An advisory lock plus a partial unique index make the rule hold even when two submissions race each other.

### Classification
The requester chooses a request type. n8n scores the title (weighted ×2) and the description against keyword lists per category, in English and Persian. It keeps the requester's choice unless the text clearly points to a single other category. Both the requester's choice and n8n's `category` are stored, together with a `classification_reason`, so every decision can be explained.

Rules were chosen over an LLM because they are deterministic, free, and keep request data inside the network. The Code node can be replaced by an LLM node later without changing anything else.

### SLA rules
- **P1:** 4 clock hours. Weekends are ignored.
- **P2 to P4:** 1, 3 or 5 business days, ending at **17:00 business time** on the last day. Saturday and Sunday are not business days.
  - Counting starts from the creation date in the business timezone, so a P2 raised on Friday, Saturday or Sunday is due Monday at 17:00.
  - A request created after 17:00 still counts the next business day as day 1. For example, a P2 raised Monday at 20:00 is due Tuesday at 17:00. This is my reading of "1 business day, ending at 17:00".
- All timestamps are `timestamptz` and stored in UTC. The business timezone (`Asia/Tehran`) and the 17:00 cut-off are rows in `app_settings`. The UI shows times in local business time.
- Closed requests are judged against `resolved_at`, not against now, so a breach stays in the history.
- Public holidays are out of scope, as the brief allows. A `holidays` table would be the extension point.
- SLA targets live in `sla_policies`, so changing one is a data change, not a code change. The same applies to departments, statuses and email recipients.

### Escalation
The workflow runs every 15 minutes. `escalate_requests()` moves open requests up a ladder that only goes up:
- **Level 1 (AT RISK):** the Automation team gets a digest email.
- **Level 2 (BREACHED):** the team lead gets a digest email.

Because the level is stored, each level is notified **once**, however often the schedule runs. `FOR UPDATE SKIP LOCKED` keeps an overlapping run, or a user editing a request, from blocking.

Trade-off: the level is committed before the email is sent, so notification is at most once. If sending still fails after 3 retries, the error workflow alerts the lead. I preferred that to a stream of repeated notifications.

### Reporting
`sla_report(from, to)` returns totals and breakdowns by department, priority and category for requests created in the period.

**SLA compliance = met ÷ decided.** "Decided" means requests whose outcome is already known: closed on time, closed late, or still open past due. Open requests that are not yet due are left out because they can still go either way, and cancelled requests are excluded.

The report page offers 7, 30 or 90 days, and its tables can be downloaded as CSV.

### Error handling and reliability
- Every webhook always answers with a clear status and a message the user can act on. Database errors are never shown to users.
- The submit, queue, report and escalation database nodes retry up to 3 times. That is safe: reads have no side effects, a retried submit either replays or is caught as a duplicate, and escalation only moves requests up the ladder.
- When a request fails with 500, the user gets their answer first. Then the execution is **deliberately failed** (Stop and Error) so that **Ops — Error alerts** emails the team lead with a link to the failed execution. Every workflow uses it as its error workflow, and its recipient is not stored in the database, so alerts still go out when the database is the thing that failed.
- The confirmation email to the requester is sent after the response and cannot fail the request.
- `request_events` is an append-only audit trail: created, status changed, assigned, escalated, duplicate blocked. The actor for queue changes is the logged-in Appsmith user.

### Security
- Appsmith never sees database credentials. It can reach only the n8n webhooks.
- n8n passes the whole payload as a single `$1::jsonb` parameter, never as SQL text. Only whitelisted fields reach the database, so a client cannot set the category, priority or status on submit.
- Employees and the Automation team use **separate apps**, so the employee app cannot show other people's requests. In production, share the team app only with the team's Appsmith group.
- The n8n Postgres credential is built from the container's environment by `setup-n8n.sh`, so no password is stored in this repository.

## Known limitations and next steps
- **Webhooks are not authenticated.** That is acceptable on a local Docker network, but production should add header auth on the webhook nodes, or keep n8n off the public network.
- **The Appsmith apps were generated through Appsmith's MCP server, which does not allow custom JavaScript.** Because of that:
  - The form does not send an `idempotency_key` yet. The duplicate rule still prevents double inserts, but a double submit shows "duplicate" instead of "already received". The fix is one binding: `crypto.randomUUID()` stored per form session.
  - Minimum lengths (title 5 characters, description 20) are checked only on the server. Its message appears in the results table under the form.
- **The queue returns every row.** That is fine for hundreds of requests. For more, add server-side paging to `list_requests`.
- **Email goes to Mailpit.** To send real email, point the `Mailpit (local SMTP)` credential at a real SMTP server.
- **PostgreSQL 16:** n8n 2.x recommends 17 and currently runs in compatibility mode. Upgrading means changing the image tag and dumping and restoring the data volume.

## Testing
- `db/tests/sla_tests.sql` covers:
  - the SLA calendar: weekends, the 17:00 cut-off, and the UTC/Tehran date boundary
  - the SLA indicator and title normalisation
  - `submit_request` for create, replay, duplicate, invalid, and resubmitting after closure
- `db/tests/operations_tests.sql` covers:
  - the queue filters, combined and with unknown values
  - updates with auditing
  - the escalation ladder, which notifies only once per level
  - the report numbers
- `scripts/smoke-test.sh` runs both test files, then calls every webhook, including the 404, 409, 422 and replay paths. The request it creates is cancelled afterwards.

## Project layout
```
docker-compose.yml        PostgreSQL 16, n8n, Appsmith CE, Mailpit
db/init/                  runs once on an empty volume, in order:
  00_databases.sql        separate database for n8n's own data
  01_schema.sql           tables, SLA functions, submit_request, change_status, v_request_queue
  02_seed.sql             departments, request types, statuses, SLA policies, settings
  03_operations.sql       list_requests, update_request, escalate_requests, sla_report
  04_demo_data.sql        14 demo requests relative to now() (delete it to start empty)
db/tests/                 SQL tests (each runs in a transaction that is rolled back)
n8n/                      the six workflows (imported by scripts/setup-n8n.sh)
appsmith/                 exported Appsmith apps (import them in the Appsmith UI)
scripts/setup-n8n.sh      imports credentials and workflows, publishes them, restarts n8n
scripts/smoke-test.sh     end-to-end checks
```
