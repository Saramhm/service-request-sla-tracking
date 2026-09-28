-- SLA / dedupe / id tests. Run inside a transaction that is rolled back:
--   docker compose exec -T postgres psql -U servicedesk -d servicedesk -v ON_ERROR_STOP=1 < db/tests/sla_tests.sql
-- Business timezone in seed: Asia/Tehran (UTC+03:30). 17:00 Tehran = 13:30 UTC.

BEGIN;

CREATE TEMP TABLE sla_cases (name text, created timestamptz, priority text, expected timestamptz);
INSERT INTO sla_cases VALUES
    -- 2026-09-28 is a Monday
    ('P1 weekday',                  '2026-09-28 06:00Z', 'P1', '2026-09-28 10:00Z'),
    ('P1 across weekend ignored',   '2026-10-02 22:00Z', 'P1', '2026-10-03 02:00Z'),
    ('P2 Mon -> Tue 17:00',         '2026-09-28 06:00Z', 'P2', '2026-09-29 13:30Z'),
    ('P2 Fri -> Mon 17:00',         '2026-10-02 06:00Z', 'P2', '2026-10-05 13:30Z'),
    ('P2 Sat -> Mon 17:00',         '2026-10-03 06:00Z', 'P2', '2026-10-05 13:30Z'),
    ('P2 Sun -> Mon 17:00',         '2026-10-04 06:00Z', 'P2', '2026-10-05 13:30Z'),
    ('P3 Wed -> Mon 17:00',         '2026-09-30 06:00Z', 'P3', '2026-10-05 13:30Z'),
    ('P4 Mon -> next Mon 17:00',    '2026-09-28 06:00Z', 'P4', '2026-10-05 13:30Z'),
    ('P4 Fri -> next Fri 17:00',    '2026-10-02 06:00Z', 'P4', '2026-10-09 13:30Z'),
    -- 21:00 UTC Mon = 00:30 Tue in Tehran: the local date decides the business day
    ('P2 UTC Mon night = Tehran Tue','2026-09-28 21:00Z', 'P2', '2026-09-30 13:30Z');

DO $$
DECLARE
    c      record;
    v_got  timestamptz;
    v_fail int := 0;
BEGIN
    FOR c IN SELECT * FROM sla_cases LOOP
        v_got := calc_due_at(c.created, c.priority);
        IF v_got IS DISTINCT FROM c.expected THEN
            RAISE WARNING 'FAIL %: expected %, got %', c.name, c.expected, v_got;
            v_fail := v_fail + 1;
        ELSE
            RAISE NOTICE 'ok   %', c.name;
        END IF;
    END LOOP;

    -- SLA indicator
    IF sla_status('OPEN', now() + interval '48 hours', NULL) <> 'ON_TRACK' THEN v_fail := v_fail + 1; RAISE WARNING 'FAIL ON_TRACK'; END IF;
    IF sla_status('OPEN', now() + interval '2 hours',  NULL) <> 'AT_RISK'  THEN v_fail := v_fail + 1; RAISE WARNING 'FAIL AT_RISK';  END IF;
    IF sla_status('OPEN', now() - interval '1 minute', NULL) <> 'BREACHED' THEN v_fail := v_fail + 1; RAISE WARNING 'FAIL BREACHED'; END IF;

    -- Title normalization
    IF normalize_title('  Monthly SALES   Report!! ') <> 'monthly sales report' THEN
        v_fail := v_fail + 1; RAISE WARNING 'FAIL normalize_title';
    END IF;

    IF v_fail > 0 THEN
        RAISE EXCEPTION '% test(s) failed', v_fail;
    END IF;
END $$;

-- submit_request end-to-end: create, replay, duplicate, invalid
DO $$
DECLARE
    v_payload jsonb := jsonb_build_object(
        'requester_name', 'Test User', 'requester_email', 'Test.User@Example.com',
        'department', 'Finance', 'request_type', 'REPORT',
        'title', 'Monthly sales report', 'description', 'Need a monthly sales report by region please',
        'declared_priority', 'P3', 'idempotency_key', '11111111-1111-1111-1111-111111111111');
    r1 jsonb; r2 jsonb; r3 jsonb; r4 jsonb;
BEGIN
    r1 := submit_request(v_payload);
    ASSERT r1->>'outcome' = 'CREATED', 'first submit should create: ' || r1;
    ASSERT r1->>'request_id' ~ '^REQ-\d{4}-\d{6}$', 'bad request_id: ' || r1;

    r2 := submit_request(v_payload);
    ASSERT r2->>'outcome' = 'REPLAY' AND r2->>'request_id' = r1->>'request_id', 'retry should replay: ' || r2;

    r3 := submit_request(v_payload || jsonb_build_object(
            'idempotency_key', '22222222-2222-2222-2222-222222222222',
            'title', '  MONTHLY sales report!! ', 'requester_email', 'test.user@example.com '));
    ASSERT r3->>'outcome' = 'DUPLICATE' AND r3->>'existing_request_id' = r1->>'request_id', 'should be duplicate: ' || r3;

    r4 := submit_request(v_payload || jsonb_build_object('requester_email', 'nope', 'idempotency_key', null));
    ASSERT r4->>'outcome' = 'INVALID', 'should be invalid: ' || r4;

    -- After closing, the same title may be submitted again
    PERFORM change_status(r1->>'request_id', 'RESOLVED', 'tester');
    r3 := submit_request(v_payload || jsonb_build_object('idempotency_key', '33333333-3333-3333-3333-333333333333'));
    ASSERT r3->>'outcome' = 'CREATED', 'closed request should not block: ' || r3;

    RAISE NOTICE 'ok   submit_request create / replay / duplicate / invalid / reopen';
END $$;

ROLLBACK;
