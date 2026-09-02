PRAGMA foreign_keys = ON;

-- Accounts predate multi-provider sign-in, so keep their original OIDC columns as the canonical
-- profile while resolving every login through this identity map. One account may have one
-- identity per provider; an individual provider identity can never belong to two accounts.
CREATE TABLE account_identities (
  oidc_issuer TEXT NOT NULL,
  oidc_subject TEXT NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL,
  PRIMARY KEY (oidc_issuer, oidc_subject),
  UNIQUE (account_id, oidc_issuer)
);
CREATE INDEX account_identities_account_idx
  ON account_identities(account_id, created_at);

INSERT INTO account_identities
  (oidc_issuer, oidc_subject, account_id, created_at, last_used_at)
SELECT oidc_issuer, oidc_subject, id, created_at, updated_at
  FROM accounts;
