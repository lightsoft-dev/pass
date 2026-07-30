PRAGMA foreign_keys = ON;

-- Joining the leaderboard is explicit. Removing this row opts the account out and
-- cascades every aggregate the account previously shared.
CREATE TABLE usage_leaderboard_profiles (
  account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  joined_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- Only daily aggregates leave the desktop. Conversation text, session ids, project
-- paths, model names, and individual requests are intentionally not stored.
CREATE TABLE usage_daily_totals (
  account_id TEXT NOT NULL REFERENCES usage_leaderboard_profiles(account_id) ON DELETE CASCADE,
  desktop_id TEXT NOT NULL REFERENCES desktops(id) ON DELETE CASCADE,
  usage_date TEXT NOT NULL CHECK (
    length(usage_date) = 10
    AND substr(usage_date, 5, 1) = '-'
    AND substr(usage_date, 8, 1) = '-'
  ),
  provider TEXT NOT NULL CHECK (provider IN ('claude', 'codex', 'pi')),
  input_tokens INTEGER NOT NULL CHECK (input_tokens >= 0),
  output_tokens INTEGER NOT NULL CHECK (output_tokens >= 0),
  cache_read_tokens INTEGER NOT NULL CHECK (cache_read_tokens >= 0),
  cache_write_tokens INTEGER NOT NULL CHECK (cache_write_tokens >= 0),
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, desktop_id, usage_date, provider)
);
CREATE INDEX usage_daily_totals_period_idx
  ON usage_daily_totals(usage_date, account_id);
