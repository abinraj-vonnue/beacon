
ALTER TABLE monitors
  ADD COLUMN IF NOT EXISTS next_check_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_monitors_due_checks
  ON monitors (next_check_at, id)
  WHERE enabled = TRUE;
