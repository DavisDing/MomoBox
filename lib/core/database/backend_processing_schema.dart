/// Backend state is deliberately excluded from portable core JSON backups.
/// The business media rows and local operation history remain intact on upgrade.
const backendProcessingSchema = <String>[
  '''CREATE TABLE IF NOT EXISTS backend_media_state (
    asset_id TEXT PRIMARY KEY,
    scope_id TEXT NOT NULL,
    state TEXT NOT NULL,
    error TEXT,
    updated_at TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS backend_media_reassign (
    asset_id TEXT PRIMARY KEY, scope_id TEXT NOT NULL,
    from_entity_id TEXT NOT NULL, product_id TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS stock_movement_sources (
    operation_id TEXT NOT NULL,
    batch_id TEXT NOT NULL,
    local_id TEXT NOT NULL UNIQUE,
    PRIMARY KEY(operation_id,batch_id)
  )''',
];
