-- EXTRACT SOURCE DECLARATIONS (create table (not as))
create table sql_sources as
  from sql_stmts
  select
    filename,
    stmt_id,
    quoted(stmt->>'$.info.table') as rel_name,
    filename.rel_id(rel_name) as rel_id,
    stmt as rel_ct_ast,

  where
    (stmt->>'$.type') = 'CREATE_STATEMENT' and
    (stmt->>'$.info.type') = 'TABLE_ENTRY' and
    (stmt->'$.info.query') = 'null'
;

-- TODO: validate that names are single component (i.e. no schema/catalog names allowed)
-- (we want *lexical*/file-based namespacing in this runtime, not physical namespacing)

delete from sql_stmts using sql_sources as parsed where sql_stmts.filename = parsed.filename and sql_stmts.stmt_id = parsed.stmt_id;

copy (from sql_sources select 'source' as rel_kind, *) to 'build' (
  format json,
  partition_by ('rel_kind', 'rel_id'), write_partition_columns true, overwrite_or_ignore,
  filename_pattern 'rel', file_extension 'json'
);
