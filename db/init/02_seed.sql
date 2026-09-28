-- Reference data. Changing SLA targets or adding a department is a data change,
-- not a code change.

INSERT INTO app_settings (key, value, description) VALUES
    ('business_timezone',    'Asia/Tehran', 'Timezone used to place 17:00 end-of-business-day'),
    ('business_day_end',     '17:00',       'Local time at which P2–P4 SLAs expire'),
    ('at_risk_window_hours', '24',          'Open requests due within this window are AT_RISK');

INSERT INTO departments (name) VALUES
    ('Finance'), ('IT'), ('HR'), ('Operations'), ('Sales'), ('Legal');

INSERT INTO request_types (code, label) VALUES
    ('REPORT',     'Report request'),
    ('DATA_FIX',   'Data fix'),
    ('ACCESS',     'Access request'),
    ('AUTOMATION', 'New automation idea'),
    ('OTHER',      'Other');

INSERT INTO request_statuses (code, label, is_terminal, sort_order) VALUES
    ('OPEN',        'Open',        false, 1),
    ('IN_PROGRESS', 'In Progress', false, 2),
    ('COMPLETED',   'Completed',   true,  3),
    ('RESOLVED',    'Resolved',    true,  4),
    ('CANCELLED',   'Cancelled',   true,  5);

INSERT INTO sla_policies (priority, label, mode, amount) VALUES
    ('P1', 'Critical — 4 clock hours',   'CLOCK_HOURS',   4),
    ('P2', 'High — 1 business day',      'BUSINESS_DAYS', 1),
    ('P3', 'Medium — 3 business days',   'BUSINESS_DAYS', 3),
    ('P4', 'Low — 5 business days',      'BUSINESS_DAYS', 5);
