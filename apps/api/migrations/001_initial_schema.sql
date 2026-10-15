-- Beacon: Initial db schema

CREATE TABLE monitors(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  name VARCHAR(120) NOT NULL,
  url TEXT NOT NULL,

  interval_seconds INTEGER NOT NULL DEFAULT 60,
  timeout_ms INTEGER NOT NULL DEFAULT 5000,
  expected_status_code INTEGER NOT NULL DEFAULT 200,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT monitors_name_not_empty
    CHECK (LENGTH(TRIM(name))>0),

  CONSTRAINT monitors_interval_range
    CHECK (interval_seconds BETWEEN 30 AND 3600),

  CONSTRAINT monitors_timeout_range
    CHECK (timeout_ms BETWEEN 100 AND 60000),

  CONSTRAINT monitors_expected_status_range
    CHECK (expected_status_code BETWEEN 100 AND 599),
  CONSTRAINT monitors_url_not_empty
    CHECK (LENGTH(TRIM(url)) > 0)
);

CREATE TABLE check_results(
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

  monitor_id UUID NOT NULL REFERENCES monitors(id) ON DELETE CASCADE,
  checked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  success BOOLEAN NOT NULL,
  status_code INTEGER,
  latency_ms INTEGER,
  error_message TEXT,

  CONSTRAINT check_results_status_code_range
    CHECK (status_code IS NULL OR status_code BETWEEN 100 AND 599),

  CONSTRAINT check_results_latency_nonnegative
    CHECK (latency_ms IS NULL OR latency_ms >=0)

);

CREATE TABLE incidents(
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  monitor_id UUID NOT NULL REFERENCES monitors(id) ON DELETE CASCADE,
  status VARCHAR(20) NOT NULL DEFAULT 'open',
  opened_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMPTZ,
  last_error TEXT,

  CONSTRAINT incidents_status_valid
    CHECK (status IN ('open' , 'resolved')),

  CONSTRAINT incidents_resolution_consistent
    CHECK (
        (status = 'open' AND resolved_at IS NULL)
        OR
        (
            status = 'resolved'
            AND resolved_at IS NOT NULL
            AND resolved_at >= opened_at
        )
    )

);

CREATE INDEX idx_incidents_monitor_status
ON incidents(monitor_id,status);

CREATE UNIQUE INDEX idx_incidents_one_open_per_monitor
    ON incidents (monitor_id)
    WHERE status = 'open';


CREATE TABLE api_keys(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(120) NOT NULL,
  key_hash CHAR(64) NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  revoked_at TIMESTAMPTZ,

  CONSTRAINT api_keys_name_not_empty
    CHECK (LENGTH(TRIM(name)) > 0)
);

