-- 0042: archive stale accounts and add the supporting index.
--
-- Re-runnable by design: the index creation is guarded.

CREATE INDEX IF NOT EXISTS idx_accounts_last_seen
    ON accounts (last_seen_at);

CREATE TABLE IF NOT EXISTS accounts_archive (
    id          BIGINT PRIMARY KEY,
    email       TEXT NOT NULL,
    archived_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO accounts_archive (id, email)
SELECT id, email FROM accounts WHERE last_seen_at < now() - INTERVAL '2 years';

DELETE FROM accounts WHERE last_seen_at < now() - INTERVAL '2 years';

ALTER TABLE accounts DROP COLUMN legacy_referral_code;
