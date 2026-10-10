#!/usr/bin/env duckdb -f
.output /dev/stderr
.print === duckbuild proof of concept ===
.print
.print Run this from the directory containing the SQL files you want to compile.
.print
.print It will produce 'build.ninja' for running them.
.print

.bail on
.echo on

/* when a model file contains a bare `select`, what name should it be associated with in the file? */
set variable default_rel_name = 'main';
set variable src_dir = coalesce(nullif(getenv('DUCKBUILD_SRC_PATH'), ''), 'src');

.read_relative lib/helpers/paths.sql
.read_relative lib/helpers/names.sql

.read_relative lib/files.sql
.read_relative lib/statements/_.sql



/* resolve all table references into model IDs */
create table sql_model_refs as (

  from sql_models,

  (
    from json_tree(sql_models.rel_select_ast)
    where (value->>'type') = 'BASE_TABLE'
  ) as rel_table_refs

  left join sql_imports on
    sql_imports.filename = sql_models.filename and
    sql_imports.stmt_id < sql_models.stmt_id

  left join sql_models as ref_sql_models on
    (
      ref_sql_models.filename = sql_models.filename and
      ref_sql_models.stmt_id < sql_models.stmt_id and
      (rel_table_refs->>'$.schema_name') = '' and
      (rel_table_refs->>'$.table_name') = ref_sql_models.rel_name
    ) or (
      ref_sql_models.filename = sql_imports.imported and
      (rel_table_refs->>'$.schema_name') = sql_imports.alias and
      (rel_table_refs->>'$.table_name') = ref_sql_models.rel_name
    )

  select
    sql_models.rel_id,
    sql_models.stmt_id as rel_stmt_id,
    rel_table_refs.fullkey as rel_table_ref_path,
    ref_sql_models.rel_id as ref_id,
    ref_sql_models.stmt_id as ref_stmt_id,

  qualify
    1 = row_number() over (
      partition by sql_models.rel_id, rel_table_ref_path
      order by sql_imports.stmt_id desc, ref_sql_models.stmt_id desc
    )

);

create view sql_relations as (
  from (
    from sql_sources
    union all by name
    from sql_models
  )

  order by
    filename,
    stmt_id,
);

-- .mode jsonlines
-- from sql_relations;

-- -- write relation json info into build folder
-- copy sql_relations to 'build' (
--   format json,
--   partition_by ('rel_kind', 'rel_id'), write_partition_columns true, overwrite_or_ignore,
--   filename_pattern 'rel', file_extension 'json'
-- );

-- -- write queries into build folder
-- copy (

--   from (
--     unpivot sql_relations
--     on columns('rel_.*_ast')
--     into name rel_stmt_kind_col value rel_stmt_ast
--   )
--   select
--     rel_kind,
--     rel_id,
--     rel_stmt_kind_col.regexp_replace('^rel_(\w+)_sql$', '\1') as rel_stmt_kind,
--     rel_stmt_ast,

--   where
--     rel_stmt_ast is not null

--   qualify
--     count(*) over (partition by rel_kind, rel_id, rel_stmt_kind) = 1
--     or error('rel_stmt_kind `' || rel_stmt_kind || '` not unique!')

-- ) to 'build' (
--   format json,
--   partition_by ('rel_kind', 'rel_id', 'rel_stmt_kind'), write_partition_columns true, overwrite_or_ignore,
--   filename_pattern 'ast', file_extension 'json'
-- );

-- -- -- write the actual ninja build
-- -- create temp table build_rules as
-- --   from sql_relations
-- --   left join sql_imports using (filename)
