-- Billing scenarios. See README.md in this directory for what each account
-- models. Loaded by the integration suite before every run.

INSERT INTO accounts (id, status, created_at) VALUES
  (1, 'active',          '2026-01-05 09:00:00+00'),
  (2, 'active',          '2026-02-10 14:30:00+00'),
  (3, 'never_activated', '2026-03-01 08:15:00+00'),
  (4, 'active',          '2026-03-12 11:00:00+00');

INSERT INTO invoices (id, account_id, status, amount_cents, issued_at, paid_at) VALUES
  (101, 1, 'paid', 4900, '2026-02-01 00:00:00+00', '2026-02-03 10:00:00+00'),
  (102, 1, 'paid', 4900, '2026-03-01 00:00:00+00', '2026-03-02 16:20:00+00'),
  (201, 2, 'open', 4900, '2026-03-10 00:00:00+00', NULL),
  (301, 3, 'paid', 4900, '2026-03-15 00:00:00+00', '2026-03-16 09:40:00+00'),
  (401, 4, 'paid', 4900, '2026-04-01 00:00:00+00', '2026-04-02 12:00:00+00'),
  (402, 4, 'void', 2500, '2026-04-20 00:00:00+00', NULL);
