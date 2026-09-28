-- Queue / update / escalation / report tests. Run inside a transaction that is rolled back:
--   docker compose exec -T postgres psql -U servicedesk -d servicedesk -v ON_ERROR_STOP=1 < db/tests/operations_tests.sql

BEGIN;

DO $$
DECLARE
    base jsonb := jsonb_build_object(
        'requester_name', 'Ops Tester', 'requester_email', 'ops.tester@example.test',
        'request_type', 'DATA_FIX', 'description', 'Totals in the ledger export do not match the source system.',
        'declared_priority', 'P3');
    a text; b text; c text;
    r jsonb;
BEGIN
    a := submit_request(base || '{"title": "Ops test A", "department": "Legal"}')->>'request_id';
    b := submit_request(base || '{"title": "Ops test B", "department": "Legal"}')->>'request_id';
    c := submit_request(base || '{"title": "Ops test C", "department": "Sales"}')->>'request_id';
    ASSERT a IS NOT NULL AND b IS NOT NULL AND c IS NOT NULL, 'setup: requests not created';

    -- Put A past due and B inside the at-risk window (CHECK due_at > created_at still holds)
    UPDATE service_requests SET created_at = now() - interval '3 days', due_at = now() - interval '1 hour'  WHERE request_id = a;
    UPDATE service_requests SET created_at = now() - interval '2 days', due_at = now() + interval '2 hours' WHERE request_id = b;

    -- list_requests: filters combine with AND; unknown values are ignored
    r := list_requests('{"department": "Legal"}');
    ASSERT (SELECT count(*) FROM jsonb_array_elements(r->'rows') x WHERE x->>'request_id' IN (a, b, c)) = 2, 'department filter: ' || r;
    r := list_requests('{"department": "legal", "sla": "BREACHED"}');
    ASSERT (SELECT array_agg(x->>'request_id') FROM jsonb_array_elements(r->'rows') x WHERE x->>'request_id' IN (a, b, c)) = ARRAY[a],
           'department + sla filter should return only A';
    r := list_requests('{"status": "undefined", "department": "ALL", "sla": ""}');
    ASSERT (SELECT count(*) FROM jsonb_array_elements(r->'rows') x WHERE x->>'request_id' IN (a, b, c)) = 3, 'junk filters must be ignored';
    ASSERT r->'rows'->0->>'sla_status' = 'BREACHED', 'most urgent open request first: ' || (r->'rows'->0);
    ASSERT (r->'rows'->0->>'sla_indicator') LIKE '%Breached', 'indicator label missing';

    -- update_request
    ASSERT update_request('{"request_id": "REQ-1999-000001", "status": "RESOLVED"}')->>'outcome' = 'NOT_FOUND', 'not found';
    ASSERT update_request(jsonb_build_object('request_id', c))->>'outcome' = 'INVALID', 'nothing to change';
    ASSERT update_request(jsonb_build_object('request_id', c, 'status', 'DONE'))->>'outcome' = 'INVALID', 'bad status';
    r := update_request(jsonb_build_object('request_id', lower(c), 'status', 'in_progress',
                                           'assigned_to', 'Ali', 'actor', 'lead@example.test', 'note', 'Picked up'));
    ASSERT r->>'outcome' = 'UPDATED' AND r->'request'->>'status' = 'IN_PROGRESS' AND r->'request'->>'assigned_to' = 'Ali', 'update: ' || r;
    ASSERT (SELECT count(*) FROM request_events WHERE request_id = c AND event_type IN ('ASSIGNED', 'STATUS_CHANGED')
                                                  AND actor = 'lead@example.test') = 2, 'update must be audited';
    ASSERT (SELECT first_response_at IS NOT NULL FROM service_requests WHERE request_id = c), 'first response not stamped';

    -- escalate_requests: A → level 2, B → level 1, C untouched; a second run escalates nothing new
    r := escalate_requests();
    ASSERT (SELECT escalation_level FROM service_requests WHERE request_id = a) = 2, 'A should be level 2';
    ASSERT (SELECT escalation_level FROM service_requests WHERE request_id = b) = 1, 'B should be level 1';
    ASSERT (SELECT escalation_level FROM service_requests WHERE request_id = c) = 0, 'C should not escalate';
    ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'breached') x WHERE x->>'request_id' = a), 'A missing from breached list';
    ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'at_risk')  x WHERE x->>'request_id' = b), 'B missing from at-risk list';
    r := escalate_requests();
    ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'at_risk' || r->'breached') x WHERE x->>'request_id' IN (a, b, c)),
           'second run must not re-notify: ' || r;
    -- B later breaches → moves up to level 2 exactly once
    UPDATE service_requests SET due_at = now() - interval '1 minute' WHERE request_id = b;
    r := escalate_requests();
    ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'breached') x WHERE x->>'request_id' = b), 'B should escalate to level 2';

    -- sla_report: resolve A late and C on time → C met, A breached
    PERFORM change_status(c, 'RESOLVED', 'tester');
    PERFORM change_status(a, 'RESOLVED', 'tester');
    r := sla_report(now() - interval '7 days', now() + interval '1 minute');
    ASSERT (SELECT (x->>'met')::int FROM jsonb_array_elements(r->'by_department') x WHERE x->>'department' = 'Sales') >= 1, 'Sales met';
    ASSERT (SELECT (x->>'breached')::int FROM jsonb_array_elements(r->'by_department') x WHERE x->>'department' = 'Legal') >= 2,
           'Legal breached (A closed late, B open past due): ' || (r->'by_department');
    ASSERT (r->'totals'->>'compliance_pct') IS NOT NULL, 'compliance should be computed';

    RAISE NOTICE 'ok   list_requests / update_request / escalate_requests / sla_report';
END $$;

ROLLBACK;
