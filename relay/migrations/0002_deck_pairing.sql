CREATE TABLE deck_pairing_challenges (
  id TEXT PRIMARY KEY,
  approve_secret_hash TEXT NOT NULL,
  poll_secret_hash TEXT NOT NULL,
  public_key_jwk TEXT NOT NULL,
  device_name TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
  desktop_id TEXT REFERENCES desktops(id) ON DELETE CASCADE,
  device_id TEXT REFERENCES devices(id) ON DELETE SET NULL,
  credential_envelope TEXT,
  approved_at INTEGER,
  delivered_at INTEGER
);
CREATE INDEX deck_pairing_challenges_expiry_idx ON deck_pairing_challenges(expires_at);
