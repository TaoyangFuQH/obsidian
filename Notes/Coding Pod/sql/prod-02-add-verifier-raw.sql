-- Add `verifier_raw` to the clinic DAG's terminal node, for every ACTIVE template.
-- Derives the terminal-node index AND the verifier node id from each template's OWN
-- contents by tool_name -- never assumes staging's index 11 or its node ids.
-- Idempotent: a second run changes nothing and still exits 0.
--
-- PREREQ: the deployed code must already accept `verifier_raw` as positional arg 8.
--   kubectl -n qh exec <pod> -- python -c "import inspect,importlib; \
--     M=importlib.import_module('app.activities.clinical_coding.clinical_coding_v1_activities'); \
--     C=[c for n,c in vars(M).items() if inspect.isclass(c) and 'Activities' in n][0]; \
--     print(list(inspect.signature(vars(C)['transform_clinical_coding_v1']).parameters))"
\set ON_ERROR_STOP on
BEGIN;

DROP TABLE IF EXISTS _dag_rollback;
CREATE TEMP TABLE _dag_rollback AS
SELECT DISTINCT t.id AS template_id, t.dag_nodes AS before_nodes
  FROM workflows.dag_template_mappings m
  JOIN workflows.dag_templates     t ON t.id = m.dag_template_id
  JOIN workflows.composer_metadata c ON c.id = m.composer_metadata_id
 WHERE c.workflow_code = 'clinical-coding'
   AND COALESCE(c.is_deleted, false) = false
   AND m.status = 'active'
   AND COALESCE(m.is_deleted, false) = false
   AND COALESCE(t.is_deleted, false) = false;

DROP TABLE IF EXISTS _loc;
CREATE TEMP TABLE _loc AS
SELECT r.template_id, (x.ord - 1)::int AS xform_idx, x.node AS xform_node,
       v.node ->> 'id' AS verifier_node_id
  FROM _dag_rollback r
  CROSS JOIN LATERAL (
       SELECT node, ord FROM jsonb_array_elements(r.before_nodes) WITH ORDINALITY AS e(node, ord)
        WHERE node->'settings'->>'tool_name' = 'transform-clinical-coding-v1') x
  CROSS JOIN LATERAL (
       SELECT node FROM jsonb_array_elements(r.before_nodes) AS e(node)
        WHERE node->'settings'->>'tool_name' = 'clinic-verifier-scoring') v;

\echo '--- located (one row per active template) ---'
SELECT template_id, xform_idx, verifier_node_id,
       jsonb_array_length(xform_node->'settings'->'arg_keys') AS arg_keys,
       jsonb_array_length(xform_node->'settings'->'inputs')   AS inputs
  FROM _loc ORDER BY template_id;

UPDATE workflows.dag_templates t
   SET dag_nodes = jsonb_set(
         t.dag_nodes,
         ARRAY[l.xform_idx::text, 'settings'],
         (l.xform_node->'settings') || jsonb_build_object(
            'arg_keys',
              CASE WHEN l.xform_node->'settings'->'arg_keys' @> '["verifier_raw"]'::jsonb
                   THEN l.xform_node->'settings'->'arg_keys'
                   ELSE (l.xform_node->'settings'->'arg_keys') || '["verifier_raw"]'::jsonb END,
            'inputs',
              CASE WHEN l.xform_node->'settings'->'inputs'
                        @> jsonb_build_array(jsonb_build_object('from_node', l.verifier_node_id))
                   THEN l.xform_node->'settings'->'inputs'
                   ELSE (l.xform_node->'settings'->'inputs')
                        || jsonb_build_array(jsonb_build_object('from_node', l.verifier_node_id)) END,
            -- canonical prose from template_v1.json, so a later diff of prod against the
            -- repo template is clean instead of showing a phantom description delta
            'description', '"Terminal node \u2014 assembles the final result_json written to workflow_run.result_json, including result_json.llm_raw (per-encounter raw LLM output / thinking / token usage: the extract votes'' records ride on amb_result, the verifier''s arrive as verifier_raw from the clinic-verifier-scoring edge)."'::jsonb)),
       updated_at = now()
  FROM _loc l
 WHERE t.id = l.template_id;

DO $$
DECLARE bad int; n int;
BEGIN
  SELECT count(*) INTO n FROM _loc;
  IF n = 0 THEN RAISE EXCEPTION 'no active clinic DAG template found -- wrong DB?'; END IF;

  SELECT count(*) INTO bad
    FROM workflows.dag_templates t JOIN _dag_rollback r ON r.template_id = t.id
   WHERE jsonb_array_length(t.dag_nodes) <> jsonb_array_length(r.before_nodes);
  IF bad > 0 THEN RAISE EXCEPTION 'node count changed on % template(s)', bad; END IF;

  SELECT count(*) INTO bad
    FROM workflows.dag_templates t JOIN _loc l ON l.template_id = t.id
   WHERE NOT (t.dag_nodes->l.xform_idx->'settings'->'arg_keys' @> '["verifier_raw"]'::jsonb)
      OR (t.dag_nodes->l.xform_idx->'settings'->'arg_keys' ->> -1) IS DISTINCT FROM 'verifier_raw'
      OR NOT (t.dag_nodes->l.xform_idx->'settings'->'inputs'
              @> jsonb_build_array(jsonb_build_object('from_node', l.verifier_node_id)));
  IF bad > 0 THEN RAISE EXCEPTION 'verifier_raw/edge not applied on % template(s)', bad; END IF;

  -- 0 changed == already applied (idempotent re-run); 1 == applied now. >1 is a bug.
  SELECT count(*) INTO bad FROM (
    SELECT t.id
      FROM workflows.dag_templates t
      JOIN _dag_rollback r ON r.template_id = t.id
      JOIN LATERAL jsonb_array_elements(t.dag_nodes)    WITH ORDINALITY a(node, o) ON true
      JOIN LATERAL jsonb_array_elements(r.before_nodes) WITH ORDINALITY b(node, o) ON b.o = a.o
     GROUP BY t.id
    HAVING count(*) FILTER (WHERE a.node IS DISTINCT FROM b.node) NOT IN (0,1)) s;
  IF bad > 0 THEN RAISE EXCEPTION 'more than one node changed on % template(s)', bad; END IF;

  RAISE NOTICE 'OK: % active template(s) verified', n;
END $$;

\echo '--- AFTER ---'
SELECT t.id,
       jsonb_array_length(t.dag_nodes->l.xform_idx->'settings'->'arg_keys') AS arg_keys,
       jsonb_array_length(t.dag_nodes->l.xform_idx->'settings'->'inputs')   AS inputs,
       jsonb_array_length(t.dag_nodes) AS nodes
  FROM workflows.dag_templates t JOIN _loc l ON l.template_id = t.id ORDER BY t.id;

COMMIT;
