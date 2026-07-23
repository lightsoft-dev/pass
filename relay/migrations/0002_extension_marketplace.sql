PRAGMA foreign_keys = ON;

CREATE TABLE marketplace_extensions (
  id TEXT PRIMARY KEY,
  owner_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  manifest_id TEXT NOT NULL,
  repository_url TEXT NOT NULL,
  name TEXT NOT NULL,
  summary TEXT NOT NULL,
  description TEXT,
  category TEXT,
  tags_json TEXT NOT NULL CHECK (json_valid(tags_json) AND json_type(tags_json) = 'array'),
  version TEXT NOT NULL,
  manifest_json TEXT NOT NULL CHECK (json_valid(manifest_json) AND json_type(manifest_json) = 'object'),
  install_count INTEGER NOT NULL DEFAULT 0 CHECK (install_count >= 0),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  hidden_at INTEGER,
  hidden_by_account_id TEXT REFERENCES accounts(id) ON DELETE SET NULL,
  deleted_at INTEGER
);
CREATE UNIQUE INDEX marketplace_extensions_repository_unique_idx
  ON marketplace_extensions(repository_url COLLATE NOCASE)
  WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX marketplace_extensions_manifest_unique_idx
  ON marketplace_extensions(manifest_id COLLATE NOCASE)
  WHERE deleted_at IS NULL;
CREATE INDEX marketplace_extensions_catalog_idx
  ON marketplace_extensions(deleted_at, hidden_at, updated_at DESC, id);
CREATE INDEX marketplace_extensions_owner_idx
  ON marketplace_extensions(owner_account_id, deleted_at, updated_at DESC);
CREATE INDEX marketplace_extensions_category_idx
  ON marketplace_extensions(category COLLATE NOCASE, deleted_at, hidden_at, updated_at DESC);

-- An account is counted at most once, even when a client retries the install request.
CREATE TABLE marketplace_extension_installs (
  extension_id TEXT NOT NULL REFERENCES marketplace_extensions(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  installed_at INTEGER NOT NULL,
  PRIMARY KEY (extension_id, account_id)
);
CREATE INDEX marketplace_extension_installs_account_idx
  ON marketplace_extension_installs(account_id, installed_at DESC);

CREATE TABLE marketplace_extension_reports (
  id TEXT PRIMARY KEY,
  extension_id TEXT NOT NULL REFERENCES marketplace_extensions(id) ON DELETE CASCADE,
  reporter_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  reason TEXT NOT NULL CHECK (reason IN ('malware', 'spam', 'misleading', 'copyright', 'other')),
  details TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  resolved_at INTEGER,
  UNIQUE (extension_id, reporter_account_id)
);
CREATE INDEX marketplace_extension_reports_review_idx
  ON marketplace_extension_reports(resolved_at, created_at DESC);
