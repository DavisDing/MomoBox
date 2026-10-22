/// Additive local schema. The bounded manifest is stored as separately
/// queryable entity rows; existing Drift-generated table APIs stay unchanged.
const initialImportSchema = <String>[
  '''CREATE TABLE IF NOT EXISTS sync_initial_import_plans (
    import_id TEXT PRIMARY KEY NOT NULL,
    scope_id TEXT NOT NULL,
    identity_json TEXT NOT NULL,
    workspace_id TEXT NOT NULL,
    local_digest TEXT NOT NULL,
    status TEXT NOT NULL,
    metadata_json TEXT NOT NULL,
    receipt_json TEXT,
    message TEXT,
    history_cursor INTEGER NOT NULL DEFAULT 0,
    history_until INTEGER NOT NULL DEFAULT 0,
    snapshot_applied INTEGER NOT NULL DEFAULT 0,
    confirm_started INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
  )''',
  '''CREATE INDEX IF NOT EXISTS sync_initial_import_scope
     ON sync_initial_import_plans(scope_id, updated_at)''',
  '''CREATE TABLE IF NOT EXISTS sync_initial_import_items (
    import_id TEXT NOT NULL REFERENCES sync_initial_import_plans(import_id),
    entity TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    payload_json TEXT NOT NULL,
    PRIMARY KEY(import_id, entity, entity_id)
  )''',
  '''CREATE TABLE IF NOT EXISTS sync_imported_history (
    scope_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    cursor INTEGER NOT NULL,
    payload_json TEXT NOT NULL,
    PRIMARY KEY(scope_id, source_id),
    UNIQUE(scope_id, cursor)
  )''',
];
