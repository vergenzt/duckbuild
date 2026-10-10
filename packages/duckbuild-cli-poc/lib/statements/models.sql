create temp table sql_models_toplevel_from_ctas as
  from sql_stmts
  select
    filename,
    stmt_id,
    [filename] as rel_scope,
    quoted(stmt->>'$.info.table') as rel_name,
    filename.rel_id(rel_name) as rel_id,
    stmt->'$.info.query.node' as rel_select_ast,
    json_merge_patch(stmt, '{"info":{"query": null}}' /* wipe out "as <select...>" node */) as rel_ct_ast,
  where
    (stmt->>'$.type') = 'CREATE_STATEMENT' and
    (stmt->>'$.info.type') = 'TABLE_ENTRY' and
    (stmt->'$.info.query') != 'null'

  qualify
    count(*) over (partition by filename, rel_name)
    or error(format('Model name `%s` in file `%s` is not unique!', rel_name, filename))
;

create temp table sql_models_toplevel_from_bare_selects as
  from sql_stmts
  select
    filename,
    stmt_id,
    [filename] as rel_scope,
    quoted(getvariable('default_rel_name')) as rel_name,
    filename.rel_id(rel_name) as rel_id,
    stmt->'$.node' as rel_select_ast,
    null as rel_ct_ast,
  where
    (stmt->>'$.node.type') = 'SELECT_NODE'
  qualify
    count(*) over (partition by filename) = 1
    or error(format('File `%s` contains more than one bare `select`!', filename))
;

create temp table sql_models_toplevel as
  from sql_models_toplevel_from_ctas
  union all
  from sql_models_toplevel_from_bare_selects
;

create table sql_models as

  with recursive sql_models_impl as (
    /* initial base case */
    from sql_models_toplevel
    select
      filename,
      stmt_id.list_append(1) as stmt_id, -- append .1 to stmt_id for main query
      rel_scope,
      rel_name,
      rel_id,
      rel_select_ast,
      rel_ct_ast

    union all

    from
      sql_models_impl as cte_parent,
      json_each(cte_parent.rel_select_ast->'$.cte_map.map[*]') as cte_record
    select
      filename,
      stmt_id[:-2].list_append(0).list_append(key::integer) as stmt_id, -- sub .1 for .0.<cte_index> for CTEs
      rel_scope.list_append(rel_name) as rel_scope, -- scoped
      quoted(cte_record.value->>'$.key') as rel_name_cte, -- cte name
      rel_id || '~' || rel_name_cte as rel_id,
      value->>'$.value.query_node' as rel_select_ast, -- extract cte query itself
      json_merge_patch(value->'$.value', json('{"query_node":null}')) as cte_info, -- capture cte ast info (without query)
  )

  from sql_models_impl
  select * replace (
    -- remove ctes from query asts now since they're captured as separate models
    json_merge_patch(rel_select_ast, '{"cte_map":{"map":[]}}') as rel_select_ast
  )
  order by stmt_id
;

delete from sql_stmts using sql_models as parsed where sql_stmts.filename = parsed.filename and sql_stmts.stmt_id = parsed.stmt_id[:1];

copy (from sql_models select 'model' as rel_kind, *) to 'build' (
  format json,
  partition_by ('rel_kind', 'rel_id'), write_partition_columns true, overwrite_or_ignore,
  filename_pattern 'rel', file_extension 'json'
);
