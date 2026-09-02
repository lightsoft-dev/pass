PRAGMA foreign_keys = ON;

-- Sign in with Apple refresh tokens are encrypted with a dedicated AES-GCM key before storage.
-- These columns follow the provider identity when it is linked to another account; they are
-- identity metadata, not user-owned account resources.
ALTER TABLE account_identities ADD COLUMN apple_refresh_token_ciphertext TEXT;
ALTER TABLE account_identities ADD COLUMN apple_refresh_token_iv TEXT;
ALTER TABLE account_identities ADD COLUMN apple_refresh_token_version INTEGER;
ALTER TABLE account_identities ADD COLUMN apple_refresh_token_updated_at INTEGER;
ALTER TABLE account_identities ADD COLUMN apple_refresh_token_revoked_at INTEGER;
ALTER TABLE account_identities ADD COLUMN apple_token_operation TEXT;
ALTER TABLE account_identities ADD COLUMN apple_token_operation_id TEXT;
ALTER TABLE account_identities ADD COLUMN apple_token_operation_started_at INTEGER;
