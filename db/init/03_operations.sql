-- =============================================================================
-- Operations: the Automation Team queue, escalation and SLA reporting.
-- Like submit_request, every function n8n calls returns jsonb and runs as one
-- transaction, so workflows only route on the result.
-- =============================================================================

INSERT INTO app_settings (key, value, description) VALUES
    ('mail_from',             'service-desk@example.com',     'Sender address for notifications'),
    ('escalation_team_email', 'automation-team@example.com',  'Receives AT_RISK warnings (escalation level 1)'),
    ('escalation_lead_email', 'automation-lead@example.com',  'Receives BREACHED escalations (escalation level 2)'),
    ('report_recipients',     'automation-lead@example.com',  'Comma-separated recipients of the daily SLA report'),
    ('queue_url',             'http://localhost:8080/applications', 'Link used in notification emails; set it to the Request Queue page URL after importing the Appsmith app')
ON CONFLICT (key) DO NOTHING;

-- Local (business timezone) display of a timestamp, e.g. "2026-09-30 17:00".
CREATE OR REPLACE FUNCTION local_time(p_ts timestamptz) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT to_char(p_ts AT TIME ZONE get_setting('business_timezone'), 'YYYY-MM-DD HH24:MI')
$$;

CREATE OR REPLACE FUNCTION sla_indicator(p_sla_status text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_sla_status
        WHEN 'ON_TRACK'  THEN '🟢 On track'
        WHEN 'AT_RISK'   THEN '🟡 At risk'
        WHEN 'BREACHED'  THEN '🔴 Breached'
        WHEN 'MET'       THEN '✅ Met'
        WHEN 'CANCELLED' THEN '⚪ Cancelled'
    END
$$;

-- -----------------------------------------------------------------------------
-- list_requests: the queue. Filters (all optional, combined with AND):
--   { "status": "OPEN", "department": "Finance", "sla": "BREACHED" }
-- Unknown or empty values (including "ALL") mean "no filter", so a UI that
-- sends an unselected dropdown still gets the full queue.
-- Open work comes first, most urgent first; closed work after, newest first.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION list_requests(p jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH f AS (
        SELECT (SELECT code FROM request_statuses WHERE code = upper(btrim(p->>'status')))  AS status,
               (SELECT name FROM departments WHERE lower(name) = lower(btrim(p->>'department'))) AS department,
               nullif(upper(btrim(coalesce(p->>'sla', ''))), '')                             AS sla
    ),
    q AS (
        SELECT v.*,
               sla_indicator(v.sla_status)  AS sla_indicator,
               local_time(v.created_at)     AS created_local,
               local_time(v.due_at)         AS due_local,
               v.status IN ('OPEN', 'IN_PROGRESS') AS is_open
          FROM v_request_queue v
    ),
    rows AS (
        SELECT q.*
          FROM q, f
         WHERE (f.status IS NULL     OR q.status = f.status)
           AND (f.department IS NULL OR q.department = f.department)
           AND (f.sla IS NULL OR f.sla NOT IN ('ON_TRACK', 'AT_RISK', 'BREACHED', 'MET', 'CANCELLED')
                OR q.sla_status = f.sla)
    )
    SELECT jsonb_build_object(
        'count', (SELECT count(*) FROM rows),
        'rows',  coalesce((SELECT jsonb_agg(to_jsonb(r) - 'is_open'
                                            ORDER BY r.is_open DESC,
                                                     CASE WHEN r.is_open THEN
                                                          CASE r.sla_status WHEN 'BREACHED' THEN 0 WHEN 'AT_RISK' THEN 1 ELSE 2 END
                                                     END,
                                                     CASE WHEN r.is_open THEN r.due_at END,
                                                     r.resolved_at DESC NULLS LAST)
                             FROM rows r), '[]'::jsonb),
        -- Whole-queue counters, independent of the filters (for the header badges)
        'summary', (SELECT jsonb_build_object(
                        'open',     count(*) FILTER (WHERE is_open),
                        'at_risk',  count(*) FILTER (WHERE is_open AND sla_status = 'AT_RISK'),
                        'breached', count(*) FILTER (WHERE is_open AND sla_status = 'BREACHED'))
                      FROM q),
        'generated_at', now())
$$;

-- -----------------------------------------------------------------------------
-- update_request: status change and/or assignment from the queue, audited.
--   { "request_id", "status"?, "assigned_to"?, "note"?, "actor"? }
-- Returns outcome UPDATED | NOT_FOUND | INVALID.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_request(p jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_id     text := upper(btrim(coalesce(p->>'request_id', '')));
    v_status text := nullif(upper(btrim(coalesce(p->>'status', ''))), '');
    v_assign text := nullif(btrim(coalesce(p->>'assigned_to', '')), '');
    v_note   text := nullif(btrim(coalesce(p->>'note', '')), '');
    v_actor  text := coalesce(nullif(btrim(coalesce(p->>'actor', '')), ''), 'automation-team');
    v_row    service_requests%ROWTYPE;
BEGIN
    SELECT * INTO v_row FROM service_requests WHERE request_id = v_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('outcome', 'NOT_FOUND',
                                  'message', format('Request %s was not found.', nullif(v_id, '')));
    END IF;
    IF v_status IS NULL AND v_assign IS NULL THEN
        RETURN jsonb_build_object('outcome', 'INVALID', 'message', 'Choose a new status or an assignee.');
    END IF;
    IF v_status IS NOT NULL AND NOT EXISTS (SELECT 1 FROM request_statuses WHERE code = v_status) THEN
        RETURN jsonb_build_object('outcome', 'INVALID', 'message', format('Unknown status %s.', v_status));
    END IF;

    IF v_assign IS DISTINCT FROM v_row.assigned_to AND v_assign IS NOT NULL THEN
        UPDATE service_requests SET assigned_to = v_assign WHERE request_id = v_id;
        INSERT INTO request_events (request_id, event_type, from_value, to_value, actor, note)
        VALUES (v_id, 'ASSIGNED', v_row.assigned_to, v_assign, v_actor, v_note);
    END IF;

    IF v_status IS NOT NULL THEN
        PERFORM change_status(v_id, v_status, v_actor, v_note);
    END IF;

    RETURN jsonb_build_object(
        'outcome', 'UPDATED',
        'message', format('%s updated.', v_id),
        'request', (SELECT to_jsonb(q) FROM v_request_queue q WHERE q.request_id = v_id));
END $$;

-- -----------------------------------------------------------------------------
-- escalate_requests: run by the n8n schedule. Escalation ladder:
--   level 1 — AT_RISK  (due within the at-risk window): warn the Automation team
--   level 2 — BREACHED (past due):                      escalate to the team lead
-- A request only ever moves up, so each level is notified exactly once no
-- matter how often the schedule runs. SKIP LOCKED lets an overlapping run
-- (or a user editing a request) proceed without waiting.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION escalate_requests(p_now timestamptz DEFAULT now()) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_items jsonb;
BEGIN
    WITH candidates AS (
        SELECT r.request_id,
               r.escalation_level AS old_level,
               CASE sla_status(r.status, r.due_at, r.resolved_at, p_now)
                   WHEN 'BREACHED' THEN 2
                   WHEN 'AT_RISK'  THEN 1
                   ELSE 0
               END AS new_level
          FROM service_requests r
         WHERE r.status IN ('OPEN', 'IN_PROGRESS')
           FOR UPDATE SKIP LOCKED
    ),
    bumped AS (
        UPDATE service_requests r
           SET escalation_level  = c.new_level,
               last_escalated_at = p_now
          FROM candidates c
         WHERE r.request_id = c.request_id
           AND c.new_level > c.old_level
        RETURNING r.*, c.old_level
    ),
    logged AS (
        INSERT INTO request_events (request_id, event_type, from_value, to_value, actor, note)
        SELECT request_id, 'ESCALATED', old_level::text, escalation_level::text, 'n8n',
               CASE escalation_level WHEN 2 THEN 'SLA breached — escalated to team lead'
                                     ELSE 'SLA at risk — Automation team warned' END
          FROM bumped
        RETURNING 1
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
               'request_id',      b.request_id,
               'title',           b.title,
               'department',      b.department,
               'priority',        b.priority,
               'status',          b.status,
               'assigned_to',     b.assigned_to,
               'requester_email', b.requester_email,
               'level',           b.escalation_level,
               'due_at',          b.due_at,
               'due_local',       local_time(b.due_at),
               'hours_to_due',    round(extract(epoch FROM (b.due_at - p_now)) / 3600.0, 1))
             ORDER BY b.due_at), '[]'::jsonb)
      INTO v_items
      FROM bumped b;

    RETURN jsonb_build_object(
        'escalated',  jsonb_array_length(v_items),
        'at_risk',    coalesce((SELECT jsonb_agg(i) FROM jsonb_array_elements(v_items) i WHERE (i->>'level')::int = 1), '[]'::jsonb),
        'breached',   coalesce((SELECT jsonb_agg(i) FROM jsonb_array_elements(v_items) i WHERE (i->>'level')::int = 2), '[]'::jsonb),
        'mail_from',  get_setting('mail_from'),
        'team_email', get_setting('escalation_team_email'),
        'lead_email', get_setting('escalation_lead_email'),
        'queue_url',  get_setting('queue_url'),
        'timezone',   get_setting('business_timezone'),
        'run_at',     p_now);
END $$;

-- -----------------------------------------------------------------------------
-- sla_report: SLA performance for requests created in [p_from, p_to).
-- SLA compliance = met / decided, where "decided" is every request whose SLA
-- outcome is already known: closed on time (MET), closed late or still open
-- past due (BREACHED). Open requests that are not yet due are left out, since
-- they can still go either way. Cancelled requests are excluded.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sla_report(p_from timestamptz DEFAULT now() - interval '30 days',
                                      p_to   timestamptz DEFAULT now()) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH base AS (
        SELECT r.*,
               sla_status(r.status, r.due_at, r.resolved_at) AS sla,
               r.status IN ('OPEN', 'IN_PROGRESS')          AS is_open,
               extract(epoch FROM (r.resolved_at - r.created_at)) / 3600.0 AS resolution_hours
          FROM service_requests r
         WHERE r.created_at >= p_from AND r.created_at < p_to
    ),
    grouped AS (
        SELECT 'department' AS dim, department AS key, * FROM base
        UNION ALL
        SELECT 'priority', priority, * FROM base
        UNION ALL
        SELECT 'category', category, * FROM base
        UNION ALL
        SELECT 'total', 'All', * FROM base
    ),
    stats AS (
        SELECT dim, key,
               count(*)                                          AS total,
               count(*) FILTER (WHERE is_open)                   AS open,
               count(*) FILTER (WHERE is_open AND sla = 'AT_RISK')  AS at_risk,
               count(*) FILTER (WHERE sla = 'BREACHED')          AS breached,
               count(*) FILTER (WHERE sla = 'MET')               AS met,
               count(*) FILTER (WHERE sla = 'CANCELLED')         AS cancelled,
               round(100.0 * count(*) FILTER (WHERE sla = 'MET')
                     / nullif(count(*) FILTER (WHERE sla IN ('MET', 'BREACHED')), 0), 1) AS compliance_pct,
               coalesce(round(100.0 * count(*) FILTER (WHERE sla = 'MET')
                     / nullif(count(*) FILTER (WHERE sla IN ('MET', 'BREACHED')), 0), 1)::text || '%', 'n/a')
                                                                 AS compliance_label,
               round(avg(resolution_hours) FILTER (WHERE sla = 'MET' OR (sla = 'BREACHED' AND NOT is_open))::numeric, 1)
                                                                 AS avg_resolution_hours
          FROM grouped
         GROUP BY dim, key
    )
    SELECT jsonb_build_object(
        'period_from',   p_from,
        'period_to',     p_to,
        'period_label',  local_time(p_from) || ' to ' || local_time(p_to) || ' (' || get_setting('business_timezone') || ')',
        'totals',        coalesce((SELECT to_jsonb(s) - 'dim' - 'key' FROM stats s WHERE dim = 'total'),
                                  jsonb_build_object('total', 0, 'open', 0, 'at_risk', 0, 'breached', 0, 'met', 0,
                                                     'cancelled', 0, 'compliance_pct', NULL, 'compliance_label', 'n/a',
                                                     'avg_resolution_hours', NULL)),
        'by_department', coalesce((SELECT jsonb_agg((to_jsonb(s) - 'dim' - 'key') || jsonb_build_object('department', s.key)
                                                    ORDER BY s.key) FROM stats s WHERE dim = 'department'), '[]'::jsonb),
        'by_priority',   coalesce((SELECT jsonb_agg((to_jsonb(s) - 'dim' - 'key') || jsonb_build_object('priority', s.key)
                                                    ORDER BY s.key) FROM stats s WHERE dim = 'priority'), '[]'::jsonb),
        'by_category',   coalesce((SELECT jsonb_agg((to_jsonb(s) - 'dim' - 'key') || jsonb_build_object('category', s.key)
                                                    ORDER BY s.total DESC) FROM stats s WHERE dim = 'category'), '[]'::jsonb),
        'by_status',     coalesce((SELECT jsonb_agg(jsonb_build_object('status', st.label, 'count', coalesce(c.n, 0))
                                                    ORDER BY st.sort_order)
                                     FROM request_statuses st
                                     LEFT JOIN (SELECT status, count(*) AS n FROM base GROUP BY status) c
                                            ON c.status = st.code), '[]'::jsonb),
        'recipients',    get_setting('report_recipients'),
        'mail_from',     get_setting('mail_from'),
        'queue_url',     get_setting('queue_url'),
        'generated_at',  now())
$$;
