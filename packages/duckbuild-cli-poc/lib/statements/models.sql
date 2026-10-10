create temp table sql_models_toplevel_from_ctas as
  from sql_stmts
  select
    filename,
    stmt_id,
    quoted(stmt->>'$.info.table') as rel_name,
    filename.rel_id(rel_name) as rel_id,
    [filename, rel_name] as rel_scope,
    stmt->'$.info.query.node' as rel_select_ast,
    json_merge_patch(stmt, '{"info":{"query": null}}' /* wipe out "as <select...>" node */) as rel_ct_ast,
  where
    (stmt->>'$.type') = 'CREATE_STATEMENT' and
    (stmt->>'$.info.type') = 'TABLE_ENTRY' and
    (stmt->'$.info.query') != 'null' and
    (
       from_json(stmt->>'$.info.qualified_name.path', '["VARCHAR"]').len() = 1
       or error(format(
         'Model `{1}` in file `{0}` specifies a catalog and/or schema name. These are not permitted.',
         filename,
         from_json(stmt->>'$.info.qualified_name.path', '["VARCHAR"]')
           .apply(lambda s: quoted(s))
           .array_to_string('.')
       ))
     )

  qualify
    count(*) over (partition by filename, rel_name)
    or error(format('Model name `%s` in file `%s` is not unique!', rel_name, filename))
;

create temp table sql_models_toplevel_from_bare_selects as
  from sql_stmts
  select
    filename,
    stmt_id,
    quoted(getvariable('default_rel_name')) as rel_name,
    filename.rel_id(rel_name) as rel_id,
    [filename, rel_name] as rel_scope,
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
      rel_name,
      rel_id,
      rel_scope,
      rel_select_ast,
      rel_ct_ast

    union all

    from
      sql_models_impl as cte_parent,
      json_each(cte_parent.rel_select_ast->'$.cte_map.map[*]') as cte_record
    select
      filename,
      stmt_id[:-2].list_append(0).list_append(key::integer) as stmt_id, -- sub .1 for .0.<cte_index> for CTEs
      quoted(cte_record.value->>'$.key') as rel_name_cte, -- cte name
      rel_id || '~' || rel_name_cte as rel_id,
      rel_scope.list_append(rel_name_cte) as rel_scope, -- scoped
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
