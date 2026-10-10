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
.read_relative lib/graph/_.sql

copy sql_relations to 'build' (
  format json,
  partition_by ('rel_kind', 'rel_id'), write_partition_columns true, overwrite_or_ignore,
  filename_pattern 'rel', file_extension 'json'
);

copy (from sql_refs select 'model' as rel_kind, * order by ref_id) to 'build' (
  format json,
  partition_by ('rel_kind', 'rel_id'), write_partition_columns false, overwrite_or_ignore,
  filename_pattern 'refs', file_extension 'ndjson'
);
