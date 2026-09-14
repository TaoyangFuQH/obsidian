-- Enable consensus_or_corroborated for clinic coding, all orgs, one transaction.
-- Surgical `||` merge: only the two abstention keys change; every other key is preserved.
-- Snapshots each row first into _abst_rollback -- that temp table IS the rollback.
\set ON_ERROR_STOP on
BEGIN;

DROP TABLE IF EXISTS _abst_rollback;
CREATE TEMP TABLE _abst_rollback AS
SELECT id, org_id, temporal_config AS before_config
  FROM workflows.composer_metadata
 WHERE workflow_code = 'clinical-coding'
   AND COALESCE(is_deleted, false) = false;

\echo '--- BEFORE ---'
SELECT org_id,
       before_config->>'abstention_enabled' AS enabled,
       before_config->>'abstention_policy'  AS policy,
       (SELECT count(*) FROM jsonb_object_keys(before_config)) AS n_keys
  FROM _abst_rollback ORDER BY org_id;

UPDATE workflows.composer_metadata m
   SET temporal_config = m.temporal_config
       || '{"abstention_enabled": true, "abstention_policy": "consensus_or_corroborated"}'::jsonb,
       updated_at = now()
  FROM _abst_rollback r
 WHERE m.id = r.id;

DO $$
DECLARE bad int; n int;
BEGIN
  SELECT count(*) INTO n FROM _abst_rollback;
  IF n = 0 THEN RAISE EXCEPTION 'no clinical-coding composer rows matched -- wrong DB?'; END IF;

  SELECT count(*) INTO bad
    FROM workflows.composer_metadata m JOIN _abst_rollback r ON r.id = m.id
   WHERE m.temporal_config->>'abstention_enabled' IS DISTINCT FROM 'true'
      OR m.temporal_config->>'abstention_policy'  IS DISTINCT FROM 'consensus_or_corroborated';
  IF bad > 0 THEN RAISE EXCEPTION 'abstention keys not set on % row(s)', bad; END IF;

  -- no key may be added or dropped beyond the two we intended
  SELECT count(*) INTO bad
    FROM workflows.composer_metadata m JOIN _abst_rollback r ON r.id = m.id
   WHERE (SELECT count(*) FROM jsonb_object_keys(m.temporal_config))
      <> (SELECT count(*) FROM jsonb_object_keys(r.before_config))
       + (CASE WHEN r.before_config ? 'abstention_enabled' THEN 0 ELSE 1 END)
       + (CASE WHEN r.before_config ? 'abstention_policy'  THEN 0 ELSE 1 END);
  IF bad > 0 THEN RAISE EXCEPTION 'key count changed on % row(s)', bad; END IF;

  RAISE NOTICE 'OK: % clinical-coding composer row(s) updated', n;
END $$;

\echo '--- AFTER ---'
SELECT m.org_id,
       m.temporal_config->>'abstention_enabled' AS enabled,
       m.temporal_config->>'abstention_policy'  AS policy,
       (SELECT count(*) FROM jsonb_object_keys(m.temporal_config)) AS n_keys
  FROM workflows.composer_metadata m JOIN _abst_rollback r ON r.id = m.id
 ORDER BY m.org_id;

COMMIT;
