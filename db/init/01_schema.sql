-- =============================================================================
-- Service Request Intake & SLA Tracking — schema
-- All timestamps are timestamptz (stored as UTC). The business timezone is only
-- used to find "17:00 on the final business day" for P2–P4.
-- =============================================================================

SET TIME ZONE 'UTC';
ALTER DATABASE servicedesk SET timezone TO 'UTC';

-- -----------------------------------------------------------------------------
-- Configuration & reference data (kept in tables so rules change without code)
-- -----------------------------------------------------------------------------
CREATE TABLE app_settings (
    key         text PRIMARY KEY,
    value       text NOT NULL,
    description text
);

CREATE TABLE departments (
    name      text PRIMARY KEY,
    is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE request_types (
    code  text PRIMARY KEY,
    label text NOT NULL
);

CREATE TABLE request_statuses (
    code        text PRIMARY KEY,
    label       text NOT NULL,
    is_terminal boolean NOT NULL,   -- terminal = SLA clock stopped
    sort_order  smallint NOT NULL
);

CREATE TABLE sla_policies (
    priority text PRIMARY KEY CHECK (priority ~ '^P[1-4]$'),
    label    text NOT NULL,
    mode     text NOT NULL CHECK (mode IN ('CLOCK_HOURS', 'BUSINESS_DAYS')),
    amount   integer NOT NULL CHECK (amount > 0)
);

-- One counter row per year → REQ-<year>-<nnnnnn>. Updated inside the submit
-- transaction, so a failed submission rolls the counter back (no gaps).
CREATE TABLE request_id_counters (
    year       integer PRIMARY KEY,
    last_value integer NOT NULL
);

-- -----------------------------------------------------------------------------
-- Core table
-- -----------------------------------------------------------------------------
CREATE TABLE service_requests (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    request_id            text NOT NULL UNIQUE CHECK (request_id ~ '^REQ-\d{4}-\d{6}$'),

    requester_name        text NOT NULL CHECK (char_length(btrim(requester_name)) BETWEEN 2 AND 100),
    requester_email       text NOT NULL CHECK (requester_email = lower(btrim(requester_email))
                                               AND requester_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    company               text,
    department            text NOT NULL REFERENCES departments(name),

    request_type          text NOT NULL REFERENCES request_types(code),  -- what the requester chose
    category              text NOT NULL REFERENCES request_types(code),  -- what n8n classified
    classification_reason text,

    title                 text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 5 AND 150),
    title_normalized      text NOT NULL,
    description           text NOT NULL CHECK (char_length(btrim(description)) >= 20),
    justification         text,
    needed_by             date,

    declared_priority     text NOT NULL REFERENCES sla_policies(priority),
    priority              text NOT NULL REFERENCES sla_policies(priority),  -- effective priority driving the SLA

    status                text NOT NULL DEFAULT 'OPEN' REFERENCES request_statuses(code),
    assigned_to           text,
    escalation_level      smallint NOT NULL DEFAULT 0,
    last_escalated_at     timestamptz,

    source                text NOT NULL DEFAULT 'appsmith',
    idempotency_key       uuid UNIQUE,

    created_at            timestamptz NOT NULL DEFAULT now(),
    due_at                timestamptz NOT NULL,
    first_response_at     timestamptz,
    resolved_at           timestamptz,
    updated_at            timestamptz NOT NULL DEFAULT now(),

    CHECK (due_at > created_at)
);

-- Duplicate rule: same requester_email + normalized title while the earlier
-- request is still active. A closed request may legitimately recur, so it does
-- not block a new one. This index is the final guard against races.
CREATE UNIQUE INDEX ux_service_requests_active_duplicate
    ON service_requests (requester_email, title_normalized)
    WHERE status IN ('OPEN', 'IN_PROGRESS');

CREATE INDEX ix_service_requests_queue  ON service_requests (status, department, due_at);
CREATE INDEX ix_service_requests_due    ON service_requests (due_at) WHERE status IN ('OPEN', 'IN_PROGRESS');
CREATE INDEX ix_service_requests_email  ON service_requests (requester_email);

-- Audit trail: every state change is recorded, never updated in place.
CREATE TABLE request_events (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    request_id  text NOT NULL REFERENCES service_requests(request_id) ON DELETE CASCADE,
    event_type  text NOT NULL,  -- CREATED, STATUS_CHANGED, ASSIGNED, ESCALATED, DUPLICATE_BLOCKED ...
    from_value  text,
    to_value    text,
    actor       text NOT NULL DEFAULT 'system',
    note        text,
    payload     jsonb,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_request_events_request ON request_events (request_id, created_at);

-- Keep updated_at honest
CREATE FUNCTION trg_touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;

CREATE TRIGGER service_requests_touch
    BEFORE UPDATE ON service_requests
    FOR EACH ROW EXECUTE FUNCTION trg_touch_updated_at();

-- -----------------------------------------------------------------------------
-- Helper functions
-- -----------------------------------------------------------------------------
CREATE FUNCTION get_setting(p_key text) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT value FROM app_settings WHERE key = p_key
$$;

-- "  Monthly SALES Report!! " and "monthly sales report" → "monthly sales report"
-- Also unifies Arabic/Persian ي/ی and ك/ک so Persian titles compare correctly.
CREATE FUNCTION normalize_title(p_title text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT btrim(regexp_replace(
               regexp_replace(translate(lower(coalesce(p_title, '')), 'يك', 'یک'),
                              '[^[:alnum:][:space:]]', ' ', 'g'),
               '\s+', ' ', 'g'))
$$;

-- SLA due date.
--   P1 (CLOCK_HOURS)   : created_at + N hours, weekends ignored.
--   P2–P4 (BUSINESS_DAYS): step forward N business days (Mon–Fri) from the
--                          creation date in the business timezone; due at
--                          17:00 local on that day, returned as UTC.
--   e.g. P2 created Fri 10:00 → Mon 17:00;  created Sat → Mon 17:00.
CREATE FUNCTION calc_due_at(p_created_at timestamptz, p_priority text) RETURNS timestamptz
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_policy sla_policies%ROWTYPE;
    v_tz     text := get_setting('business_timezone');
    v_end    time := get_setting('business_day_end')::time;
    v_day    date;
    v_left   integer;
BEGIN
    SELECT * INTO v_policy FROM sla_policies WHERE priority = p_priority;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown priority: %', p_priority USING ERRCODE = '22023';
    END IF;

    IF v_policy.mode = 'CLOCK_HOURS' THEN
        RETURN p_created_at + make_interval(hours => v_policy.amount);
    END IF;

    v_day  := (p_created_at AT TIME ZONE v_tz)::date;
    v_left := v_policy.amount;
    WHILE v_left > 0 LOOP
        v_day := v_day + 1;
        IF extract(isodow FROM v_day) < 6 THEN   -- 6 = Sat, 7 = Sun
            v_left := v_left - 1;
        END IF;
    END LOOP;

    RETURN (v_day + v_end) AT TIME ZONE v_tz;
END $$;

-- SLA indicator. Open work is judged against now(); closed work against when it
-- was resolved, so the history of breaches is preserved.
CREATE FUNCTION sla_status(p_status text, p_due_at timestamptz, p_resolved_at timestamptz,
                           p_now timestamptz DEFAULT now()) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN p_status = 'CANCELLED'                   THEN 'CANCELLED'
        WHEN p_status IN ('COMPLETED', 'RESOLVED')    THEN
             CASE WHEN coalesce(p_resolved_at, p_now) <= p_due_at THEN 'MET' ELSE 'BREACHED' END
        WHEN p_now > p_due_at                         THEN 'BREACHED'
        WHEN p_due_at - p_now <= make_interval(hours => get_setting('at_risk_window_hours')::int)
                                                      THEN 'AT_RISK'
        ELSE 'ON_TRACK'
    END
$$;

-- -----------------------------------------------------------------------------
-- submit_request: the single, atomic write path used by n8n.
-- One call = one transaction: validate → idempotency → duplicate check →
-- generate request_id → compute SLA → insert → audit event.
-- Returns jsonb with outcome CREATED | REPLAY | DUPLICATE | INVALID.
-- Unexpected errors raise and roll everything back.
-- -----------------------------------------------------------------------------
CREATE FUNCTION submit_request(p jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_errors      text[] := '{}';
    v_email       text   := lower(btrim(coalesce(p->>'requester_email', '')));
    v_name        text   := btrim(coalesce(p->>'requester_name', ''));
    v_title       text   := btrim(coalesce(p->>'title', ''));
    v_desc        text   := btrim(coalesce(p->>'description', ''));
    v_dept        text   := p->>'department';
    v_type        text   := p->>'request_type';
    v_category    text   := coalesce(p->>'category', p->>'request_type');
    v_declared    text   := upper(p->>'declared_priority');
    v_priority    text   := upper(coalesce(p->>'priority', p->>'declared_priority'));
    v_key         uuid;
    v_norm        text;
    v_now         timestamptz := now();
    v_year        integer;
    v_seq         integer;
    v_request_id  text;
    v_due_at      timestamptz;
    v_existing    service_requests%ROWTYPE;
BEGIN
    -- 1. Validation (mirrors the form; the server never trusts the client)
    IF char_length(v_name) NOT BETWEEN 2 AND 100 THEN
        v_errors := array_append(v_errors, 'requester_name must be 2–100 characters');
    END IF;
    IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
        v_errors := array_append(v_errors, 'requester_email is not a valid email');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM departments WHERE name = v_dept AND is_active) THEN
        v_errors := array_append(v_errors, format('department "%s" is not valid', coalesce(v_dept, '')));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM request_types WHERE code = v_type) THEN
        v_errors := array_append(v_errors, format('request_type "%s" is not valid', coalesce(v_type, '')));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM request_types WHERE code = v_category) THEN
        v_errors := array_append(v_errors, format('category "%s" is not valid', coalesce(v_category, '')));
    END IF;
    IF char_length(v_title) NOT BETWEEN 5 AND 150 THEN
        v_errors := array_append(v_errors, 'title must be 5–150 characters');
    END IF;
    IF char_length(v_desc) < 20 THEN
        v_errors := array_append(v_errors, 'description must be at least 20 characters');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM sla_policies WHERE priority = v_declared) THEN
        v_errors := array_append(v_errors, 'declared_priority must be P1–P4');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM sla_policies WHERE priority = v_priority) THEN
        v_errors := array_append(v_errors, 'priority must be P1–P4');
    END IF;
    IF v_declared = 'P1' AND nullif(btrim(coalesce(p->>'justification', '')), '') IS NULL THEN
        v_errors := array_append(v_errors, 'justification is required for P1 requests');
    END IF;
    BEGIN
        v_key := nullif(p->>'idempotency_key', '')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
        v_errors := array_append(v_errors, 'idempotency_key must be a UUID');
    END;

    IF cardinality(v_errors) > 0 THEN
        RETURN jsonb_build_object('outcome', 'INVALID', 'errors', to_jsonb(v_errors));
    END IF;

    v_norm := normalize_title(v_title);

    -- 2. Serialise concurrent submissions of the same logical request
    PERFORM pg_advisory_xact_lock(hashtextextended(v_email || '|' || v_norm, 0));
    IF v_key IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(hashtextextended(v_key::text, 0));
    END IF;

    -- 3. Idempotency: the same submission retried (double-click, network retry)
    IF v_key IS NOT NULL THEN
        SELECT * INTO v_existing FROM service_requests WHERE idempotency_key = v_key;
        IF FOUND THEN
            RETURN jsonb_build_object(
                'outcome',    'REPLAY',
                'request_id', v_existing.request_id,
                'created_at', v_existing.created_at,
                'due_at',     v_existing.due_at,
                'priority',   v_existing.priority,
                'sla_status', sla_status(v_existing.status, v_existing.due_at, v_existing.resolved_at));
        END IF;
    END IF;

    -- 4. Business duplicate: same email + normalized title still active
    SELECT * INTO v_existing
      FROM service_requests
     WHERE requester_email = v_email
       AND title_normalized = v_norm
       AND status IN ('OPEN', 'IN_PROGRESS')
     LIMIT 1;
    IF FOUND THEN
        INSERT INTO request_events (request_id, event_type, actor, note, payload)
        VALUES (v_existing.request_id, 'DUPLICATE_BLOCKED', v_email,
                'A duplicate submission was rejected', p);
        RETURN jsonb_build_object(
            'outcome',             'DUPLICATE',
            'existing_request_id', v_existing.request_id,
            'existing_status',     v_existing.status,
            'due_at',              v_existing.due_at);
    END IF;

    -- 5. request_id: REQ-<year>-<6 digits>, per-year counter, gap-free
    v_year := extract(year FROM v_now AT TIME ZONE get_setting('business_timezone'))::int;
    INSERT INTO request_id_counters AS c (year, last_value) VALUES (v_year, 1)
    ON CONFLICT (year) DO UPDATE SET last_value = c.last_value + 1
    RETURNING last_value INTO v_seq;
    v_request_id := format('REQ-%s-%s', v_year, lpad(v_seq::text, 6, '0'));

    -- 6. SLA
    v_due_at := calc_due_at(v_now, v_priority);

    -- 7. Insert + audit
    INSERT INTO service_requests (
        request_id, requester_name, requester_email, company, department,
        request_type, category, classification_reason,
        title, title_normalized, description, justification, needed_by,
        declared_priority, priority, source, idempotency_key, created_at, due_at)
    VALUES (
        v_request_id, v_name, v_email, nullif(btrim(coalesce(p->>'company', '')), ''), v_dept,
        v_type, v_category, p->>'classification_reason',
        v_title, v_norm, v_desc, nullif(btrim(coalesce(p->>'justification', '')), ''),
        nullif(p->>'needed_by', '')::date,
        v_declared, v_priority, coalesce(p->>'source', 'appsmith'), v_key, v_now, v_due_at);

    INSERT INTO request_events (request_id, event_type, to_value, actor, payload)
    VALUES (v_request_id, 'CREATED', 'OPEN', v_email, p);

    IF v_priority <> v_declared THEN
        INSERT INTO request_events (request_id, event_type, from_value, to_value, actor, note)
        VALUES (v_request_id, 'PRIORITY_ADJUSTED', v_declared, v_priority, 'n8n',
                p->>'classification_reason');
    END IF;

    RETURN jsonb_build_object(
        'outcome',    'CREATED',
        'request_id', v_request_id,
        'created_at', v_now,
        'due_at',     v_due_at,
        'priority',   v_priority,
        'category',   v_category,
        'sla_status', sla_status('OPEN', v_due_at, NULL));
END $$;

-- -----------------------------------------------------------------------------
-- change_status: used by the Automation Team queue (Appsmith). Audited.
-- -----------------------------------------------------------------------------
CREATE FUNCTION change_status(p_request_id text, p_new_status text, p_actor text,
                              p_note text DEFAULT NULL) RETURNS service_requests
LANGUAGE plpgsql AS $$
DECLARE
    v_row      service_requests%ROWTYPE;
    v_terminal boolean;
    v_old      text;
BEGIN
    SELECT * INTO v_row FROM service_requests WHERE request_id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Request % not found', p_request_id USING ERRCODE = 'P0002';
    END IF;

    SELECT is_terminal INTO v_terminal FROM request_statuses WHERE code = p_new_status;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown status %', p_new_status USING ERRCODE = '22023';
    END IF;

    IF v_row.status = p_new_status THEN
        RETURN v_row;
    END IF;
    v_old := v_row.status;

    UPDATE service_requests
       SET status            = p_new_status,
           first_response_at = coalesce(first_response_at,
                                        CASE WHEN p_new_status <> 'OPEN' THEN now() END),
           resolved_at       = CASE WHEN v_terminal THEN now() ELSE NULL END
     WHERE request_id = p_request_id
    RETURNING * INTO v_row;

    INSERT INTO request_events (request_id, event_type, from_value, to_value, actor, note)
    VALUES (p_request_id, 'STATUS_CHANGED', v_old, p_new_status, p_actor, p_note);

    RETURN v_row;
END $$;

-- -----------------------------------------------------------------------------
-- Read models for Appsmith and reporting
-- -----------------------------------------------------------------------------
CREATE VIEW v_request_queue AS
SELECT r.request_id,
       r.title,
       r.requester_name,
       r.requester_email,
       r.company,
       r.department,
       r.request_type,
       r.category,
       r.declared_priority,
       r.priority,
       r.status,
       s.label                                                   AS status_label,
       r.assigned_to,
       r.escalation_level,
       r.created_at,
       r.due_at,
       r.resolved_at,
       sla_status(r.status, r.due_at, r.resolved_at)             AS sla_status,
       round(extract(epoch FROM (r.due_at - now())) / 3600.0, 1) AS hours_to_due,
       r.description,
       r.justification,
       r.needed_by
  FROM service_requests r
  JOIN request_statuses s ON s.code = r.status;
