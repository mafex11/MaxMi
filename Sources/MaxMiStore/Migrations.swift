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
        return m
    }
}
