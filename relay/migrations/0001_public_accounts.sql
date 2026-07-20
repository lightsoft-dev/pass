PRAGMA foreign_keys = ON;

CREATE TABLE accounts (
  id TEXT PRIMARY KEY,
  oidc_issuer TEXT NOT NULL,
  oidc_subject TEXT NOT NULL,
  email TEXT,
  display_name TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE (oidc_issuer, oidc_subject)
);

CREATE TABLE desktops (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER,
  revoked_at INTEGER
);
CREATE INDEX desktops_account_idx ON desktops(account_id, created_at);

CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  platform TEXT NOT NULL CHECK (platform IN ('ios', 'android', 'macos', 'unknown')),
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER,
  revoked_at INTEGER
);
CREATE INDEX devices_account_idx ON devices(account_id, created_at);

CREATE TABLE desktop_devices (
  desktop_id TEXT NOT NULL REFERENCES desktops(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  scopes_json TEXT NOT NULL,
  paired_at INTEGER NOT NULL,
  revoked_at INTEGER,
  PRIMARY KEY (desktop_id, device_id)
);
CREATE INDEX desktop_devices_device_idx ON desktop_devices(device_id, paired_at);

CREATE TABLE pairing_challenges (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  desktop_id TEXT NOT NULL REFERENCES desktops(id) ON DELETE CASCADE,
  secret_hash TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  claimed_at INTEGER,
  claimed_device_id TEXT REFERENCES devices(id) ON DELETE SET NULL
);
CREATE INDEX pairing_challenges_expiry_idx ON pairing_challenges(expires_at);

CREATE TABLE credentials (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  subject_type TEXT NOT NULL CHECK (subject_type IN ('desktop', 'device')),
  subject_id TEXT NOT NULL,
  desktop_id TEXT NOT NULL REFERENCES desktops(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('desktop', 'mobile')),
  kind TEXT NOT NULL CHECK (kind IN ('access', 'refresh')),
  secret_hash TEXT NOT NULL,
  scopes_json TEXT NOT NULL,
  issued_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  revoked_at INTEGER,
  replaced_by TEXT REFERENCES credentials(id) ON DELETE SET NULL
);
CREATE INDEX credentials_subject_idx ON credentials(subject_type, subject_id, kind);
CREATE INDEX credentials_expiry_idx ON credentials(expires_at);

CREATE TABLE audit_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id TEXT NOT NULL,
  actor_type TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  action TEXT NOT NULL,
  target_type TEXT,
  target_id TEXT,
  occurred_at INTEGER NOT NULL
);
CREATE INDEX audit_events_account_time_idx ON audit_events(account_id, occurred_at DESC);
