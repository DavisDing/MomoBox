-- Keep existing values/data and repair only a provably too-small lower bound.
-- Older restock commands updated quantity but not initial_quantity. Historical
-- records may be incomplete: do not invent amounts that were never recorded.
BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended('momobox:postgres:migrations', 0));
SET LOCAL TIME ZONE 'UTC';
SET LOCAL search_path = public;

-- A command writes the batch before appending its consumption record. Waiting
-- for batch writers also prevents racing the known-restock aggregate below.
LOCK TABLE product_batches IN SHARE ROW EXCLUSIVE MODE;

WITH known_restock AS (
    SELECT family_id, batch_id, SUM(quantity_change::bigint) AS stocked_quantity
    FROM consumption_records
    WHERE record_type = 'restock' AND quantity_change > 0
    GROUP BY family_id, batch_id
), bounds AS (
    SELECT b.id, b.family_id,
           GREATEST(b.initial_quantity::bigint, b.quantity::bigint,
                    COALESCE(r.stocked_quantity, 0)) AS repaired_initial
    FROM product_batches AS b
    LEFT JOIN known_restock AS r ON r.family_id = b.family_id AND r.batch_id = b.id
    WHERE b.deleted_at IS NULL
), repaired AS (
    UPDATE product_batches AS b
    SET initial_quantity = bounds.repaired_initial::integer,
        version = b.version + 1,
        updated_at = CURRENT_TIMESTAMP
    FROM bounds
    WHERE b.id = bounds.id AND b.family_id = bounds.family_id
      AND b.initial_quantity::bigint < bounds.repaired_initial
    RETURNING b.*
)
INSERT INTO change_log (change_id, family_id, operation, entity, entity_id,
                        version, payload, updated_by_device)
SELECT gen_random_uuid(), family_id, 'entity_upsert', 'product_batches', id,
       version, to_jsonb(repaired) - 'family_id', updated_by_device
FROM repaired;

COMMIT;
