create table sql_sources as
  from sql_stmts
  select
    filename,
    stmt_id,
    quoted(stmt->>'$.info.table') as rel_name,
    filename.rel_id(rel_name) as rel_id,
    [filename, rel_name] as rel_scope,
    stmt as rel_ct_ast,
  where list_bool_and([
    (stmt->>'$.type') = 'CREATE_STATEMENT',
    (stmt->>'$.info.type') = 'TABLE_ENTRY',
    (stmt->'$.info.query') = 'null',
  ]) and (
    from_json(stmt->>'$.info.qualified_name.path', '["VARCHAR"]').len() = 1
    or error(format(
      'Source `{1}` in file `{0}` specifies a catalog and/or schema name. These are not permitted.',
      filename,
      from_json(stmt->>'$.info.qualified_name.path', '["VARCHAR"]')
        .apply(lambda s: quoted(s))
        .array_to_string('.')
    ))
  )
;

-- TODO: validate that names are single component (i.e. no schema/catalog names allowed)
-- (we want *lexical*/file-based namespacing in this runtime, not physical namespacing)

delete from sql_stmts using sql_sources as parsed where sql_stmts.filename = parsed.filename and sql_stmts.stmt_id = parsed.stmt_id;
