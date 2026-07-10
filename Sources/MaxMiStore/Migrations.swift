import GRDB

enum Migrations {
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE threads (
              id             TEXT PRIMARY KEY,
              source_app     TEXT NOT NULL,
              source_key     TEXT NOT NULL,
              source_title   TEXT,
              last_tree_hash TEXT,
              created_at     INTEGER NOT NULL,
              updated_at     INTEGER NOT NULL,
              UNIQUE(source_app, source_key)
            );
            CREATE TABLE versions (
              id             TEXT PRIMARY KEY,
              thread_id      TEXT NOT NULL REFERENCES threads(id),
              hour_bucket    INTEGER NOT NULL,
              content        TEXT NOT NULL,
              content_hash   TEXT NOT NULL,
              word_count     INTEGER NOT NULL DEFAULT 0,
              is_frozen      INTEGER NOT NULL DEFAULT 0,
              committed_at   INTEGER NOT NULL,
              extract_status TEXT NOT NULL DEFAULT 'pending',
              UNIQUE(thread_id, hour_bucket)
            );
            CREATE INDEX idx_versions_thread ON versions(thread_id);
            CREATE TABLE derivatives (
              id               TEXT PRIMARY KEY,
              thread_id        TEXT NOT NULL REFERENCES threads(id),
              version_id       TEXT NOT NULL REFERENCES versions(id),
              content          TEXT NOT NULL,
              content_hash     TEXT NOT NULL,
              committed_at     INTEGER NOT NULL,
              embedding_status TEXT NOT NULL DEFAULT 'pending',
              UNIQUE(thread_id, content_hash)
            );
            CREATE INDEX idx_derivatives_version ON derivatives(version_id);
            CREATE TABLE retry_queue (
              id              TEXT PRIMARY KEY,
              kind            TEXT NOT NULL,
              version_id      TEXT,
              derivative_id   TEXT,
              attempts        INTEGER NOT NULL DEFAULT 0,
              next_attempt_at INTEGER NOT NULL,
              last_error      TEXT
            );
            CREATE INDEX idx_retry_due ON retry_queue(next_attempt_at);
            CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL);
            CREATE TABLE schema_migrations (id TEXT PRIMARY KEY, applied_at INTEGER NOT NULL);
            """)
            try db.execute(sql: """
            CREATE VIRTUAL TABLE derivative_embeddings USING vec0(
              derivative_id TEXT PRIMARY KEY,
              embedding     FLOAT[1536]
            );
            """)
        }
        m.registerMigration("v2") { db in
            try db.execute(sql: """
            CREATE TABLE message_fingerprints (
              fingerprint  TEXT PRIMARY KEY,
              thread_id    TEXT NOT NULL REFERENCES threads(id),
              seen_at      INTEGER NOT NULL
            );
            CREATE INDEX idx_fingerprints_thread ON message_fingerprints(thread_id);
            """)
        }
        m.registerMigration("v3") { db in
            try db.execute(sql: "ALTER TABLE versions ADD COLUMN metadata TEXT;")
            try db.execute(sql: """
            CREATE TABLE meetings (
              id           TEXT PRIMARY KEY,
              thread_id    TEXT NOT NULL REFERENCES threads(id),
              version_id   TEXT REFERENCES versions(id),
              app          TEXT NOT NULL,
              title        TEXT,
              started_at   INTEGER NOT NULL,
              ended_at     INTEGER,
              state        TEXT NOT NULL,
              capture_mode TEXT NOT NULL,
              transcription_status TEXT NOT NULL DEFAULT 'pending',
              UNIQUE(version_id),
              UNIQUE(thread_id)
            );
            CREATE INDEX idx_meetings_started ON meetings(started_at DESC);
            """)
        }
        m.registerMigration("v4") { db in
            try db.execute(sql: """
            CREATE TABLE activity_app_visits (
              id TEXT PRIMARY KEY, app_bundle TEXT NOT NULL, app_label TEXT NOT NULL,
              started_at INTEGER NOT NULL, ended_at INTEGER, day_bucket INTEGER NOT NULL);
            CREATE INDEX idx_visits_day ON activity_app_visits(day_bucket DESC, started_at DESC);
            CREATE INDEX idx_visits_open ON activity_app_visits(ended_at) WHERE ended_at IS NULL;

            CREATE TABLE activity_sessions (
              id TEXT PRIMARY KEY, app_bundle TEXT NOT NULL, app_label TEXT NOT NULL,
              started_at INTEGER NOT NULL, ended_at INTEGER, last_activity_at INTEGER NOT NULL,
              day_bucket INTEGER NOT NULL,
              summary_ciphertext TEXT,
              summary_status TEXT NOT NULL DEFAULT 'pending'
                CHECK(summary_status IN ('pending','summarized','failed','skipped')),
              summary_attempts INTEGER DEFAULT 0,
              summary_next_attempt_at INTEGER,
              source_hash TEXT,
              model_id TEXT, prompt_version TEXT,
              created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
            CREATE INDEX idx_sessions_day ON activity_sessions(day_bucket DESC, started_at DESC);
            CREATE INDEX idx_sessions_summ ON activity_sessions(summary_status) WHERE summary_status='pending';

            CREATE TABLE activity_session_evidence (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL REFERENCES activity_sessions(id) ON DELETE CASCADE,
              version_id TEXT REFERENCES versions(id),
              captured_at INTEGER NOT NULL,
              content_hash TEXT NOT NULL,
              content_ciphertext TEXT NOT NULL);
            CREATE INDEX idx_evidence_session ON activity_session_evidence(session_id, captured_at);
            CREATE UNIQUE INDEX idx_evidence_dedup ON activity_session_evidence(session_id, content_hash);

            CREATE TABLE agent_runs (
              id TEXT PRIMARY KEY, kind TEXT NOT NULL,
              status TEXT NOT NULL CHECK(status IN ('running','completed','failed')),
              input_from INTEGER, input_to INTEGER,
              model_id TEXT, prompt_version TEXT,
              started_at INTEGER NOT NULL, ended_at INTEGER, day_bucket INTEGER NOT NULL,
              new_count INTEGER, resolved_count INTEGER, updated_count INTEGER,
              new_item_ids TEXT, resolved_item_ids TEXT, updated_item_ids TEXT,
              error TEXT);
            CREATE INDEX idx_runs_started ON agent_runs(started_at DESC);

            CREATE TABLE agent_action_items (
              id TEXT PRIMARY KEY, kind TEXT NOT NULL,
              status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','resolved','dismissed')),
              title_ciphertext TEXT NOT NULL,
              details_ciphertext TEXT,
              source_refs TEXT,
              detected_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
              resolved_at INTEGER, resolution_evidence_ciphertext TEXT);
            CREATE INDEX idx_items_status ON agent_action_items(status, detected_at DESC);

            CREATE TABLE agent_action_item_events (
              id TEXT PRIMARY KEY, item_id TEXT NOT NULL REFERENCES agent_action_items(id) ON DELETE CASCADE,
              event TEXT NOT NULL, run_id TEXT, at INTEGER NOT NULL);
            """)
        }
        return m
    }
}
