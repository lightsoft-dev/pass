PRAGMA foreign_keys = ON;

-- Feedback is durably accepted in D1 before any optional Notion delivery is attempted.
-- The report id returned to the client is also the deletion/support lookup key.
CREATE TABLE feedback_reports (
  id TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('request', 'feedback', 'bug')),
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  email TEXT,
  app_version TEXT,
  os_version TEXT,
  forward_status TEXT NOT NULL DEFAULT 'queued'
    CHECK (forward_status IN ('queued', 'delivered')),
  forwarded_at INTEGER,
  CHECK (
    (forward_status = 'queued' AND forwarded_at IS NULL)
    OR (forward_status = 'delivered' AND forwarded_at IS NOT NULL)
  )
);

CREATE INDEX feedback_reports_forward_queue_idx
  ON feedback_reports(forward_status, created_at);
