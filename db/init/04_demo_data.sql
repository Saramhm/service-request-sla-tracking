-- =============================================================================
-- Demo data: a realistic queue so the Appsmith screens and the SLA report are
-- not empty on first start. Times are relative to now(), so every load has
-- requests that are on track, at risk and breached (the exact mix of P2–P4
-- states depends on the weekday, as it would in real life).
-- Requests go through submit_request() like real ones, then are back-dated.
-- To start with an empty database, delete this file before the first
-- `docker compose up` (it only runs on an empty volume).
-- =============================================================================

DO $$
DECLARE
    d   record;
    v   jsonb;
    v_id text;
    t0  timestamptz;
BEGIN
    FOR d IN
        SELECT * FROM (VALUES
        -- name,             email,                       dept,         type,         title,                                          priority, age,         status,        closed_after, assignee, justification
        ('Neda Karimi',      'neda.karimi@example.com',    'Finance',    'REPORT',     'Monthly revenue by region',                    'P3', interval '1 day',   'OPEN',        NULL::interval, NULL,     NULL),
        ('Omid Rahimi',      'omid.rahimi@example.com',    'Sales',      'DATA_FIX',   'Duplicate customers in the CRM export',        'P1', interval '5 hours', 'OPEN',        NULL,           NULL,     'Quarter-end commission run depends on this export'),
        ('Leila Ahmadi',     'leila.ahmadi@example.com',   'IT',         'DATA_FIX',   'Wrong cost centre on 40 supplier invoices',    'P1', interval '1 hour',  'IN_PROGRESS', NULL,           'Reza',   'Month-end close is tomorrow'),
        ('Kian Moradi',      'kian.moradi@example.com',    'Operations', 'AUTOMATION', 'Automate the daily stock reconciliation',      'P4', interval '2 days',  'IN_PROGRESS', NULL,           'Mina',   NULL),
        ('Sara Hosseini',    'sara.hosseini@example.com',  'HR',         'REPORT',     'Headcount dashboard by department',            'P3', interval '10 days', 'IN_PROGRESS', NULL,           'Mina',   NULL),
        ('Arash Jafari',     'arash.jafari@example.com',   'Legal',      'OTHER',      'Reminders for contracts expiring next month',  'P4', interval '1 day',   'OPEN',        NULL,           NULL,     NULL),
        ('Maryam Sadeghi',   'maryam.sadeghi@example.com', 'Finance',    'ACCESS',     'Read access to the budget planning model',     'P2', interval '3 hours', 'OPEN',        NULL,           NULL,     NULL),
        ('Babak Nouri',      'babak.nouri@example.com',    'IT',         'ACCESS',     'Data warehouse access for the new analyst',    'P2', interval '4 days',  'OPEN',        NULL,           NULL,     NULL),
        ('Neda Karimi',      'neda.karimi@example.com',    'Finance',    'REPORT',     'Weekly cash position report',                  'P3', interval '9 days',  'RESOLVED',    interval '2 days',   'Reza', NULL),
        ('Omid Rahimi',      'omid.rahimi@example.com',    'Sales',      'REPORT',     'Pipeline report by account owner',             'P2', interval '8 days',  'COMPLETED',   interval '3 days',   'Ali',  NULL),
        ('Sara Hosseini',    'sara.hosseini@example.com',  'HR',         'ACCESS',     'HRIS read access for the payroll team',        'P2', interval '6 days',  'RESOLVED',    interval '5 hours',  'Ali',  NULL),
        ('Kian Moradi',      'kian.moradi@example.com',    'Operations', 'DATA_FIX',   'Correct warehouse codes after the migration',  'P1', interval '7 days',  'RESOLVED',    interval '3 hours',  'Reza', 'Shipments are blocked at two warehouses'),
        ('Arash Jafari',     'arash.jafari@example.com',   'Legal',      'AUTOMATION', 'Automate NDA intake from the shared mailbox',  'P4', interval '20 days', 'CANCELLED',   interval '1 day',    NULL,   NULL),
        ('Babak Nouri',      'babak.nouri@example.com',    'IT',         'OTHER',      'Archive old SharePoint report sites',          'P4', interval '15 days', 'COMPLETED',   interval '9 days',   'Mina', NULL)
        ) AS x(name, email, dept, rtype, title, priority, age, status, closed_after, assignee, justification)
    LOOP
        t0 := now() - d.age;
        v := submit_request(jsonb_build_object(
                'requester_name', d.name, 'requester_email', d.email, 'department', d.dept,
                'request_type', d.rtype, 'category', d.rtype,
                'classification_reason', 'Demo data: kept the requester''s choice',
                'title', d.title,
                'description', d.title || '. Details were provided by the requester in the demo data set.',
                'declared_priority', d.priority, 'justification', d.justification, 'source', 'demo'));
        v_id := v->>'request_id';
        IF v_id IS NULL THEN
            RAISE EXCEPTION 'demo request "%" was not created: %', d.title, v;
        END IF;

        UPDATE service_requests
           SET created_at = t0, due_at = calc_due_at(t0, d.priority), assigned_to = d.assignee
         WHERE request_id = v_id;
        UPDATE request_events SET created_at = t0 WHERE request_id = v_id;

        IF d.status <> 'OPEN' THEN
            PERFORM change_status(v_id, d.status, coalesce(d.assignee, 'automation-team'), 'Demo data');
            UPDATE service_requests
               SET first_response_at = t0 + least(coalesce(d.closed_after, interval '2 hours'), interval '2 hours', d.age / 2),
                   resolved_at       = CASE WHEN d.closed_after IS NOT NULL THEN t0 + d.closed_after END
             WHERE request_id = v_id;
            UPDATE request_events
               SET created_at = t0 + coalesce(d.closed_after, least(interval '2 hours', d.age / 2))
             WHERE request_id = v_id AND event_type = 'STATUS_CHANGED';
        END IF;
    END LOOP;
END $$;
