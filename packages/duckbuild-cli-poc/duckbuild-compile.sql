#!/usr/bin/env duckdb -f
.output /dev/stderr
.print === duckbuild proof of concept ===
.print
.print Run this from the directory containing the SQL files you want to compile.
.print
.print It will produce 'build.ninja' for running them.
.print

.bail on

/* when a model file contains a bare `select`, what qualname should it be associated with in the file? */
set variable default_qualname = 'main';

create function is_abs(path) as path like '/%';
create function is_rel(path) as not path.is_abs();
create function abs(path) as
  case when path.is_abs() then path
  else getenv('PWD') || '/' || path end
;

create function normalize_path(path, relbase:='.') as
  list_reduce(
    parse_path(concat(relbase, '/', path)),
    lambda path_acc, part: (
      case part
      when '.' then path_acc
      when '..' then case
        when path_acc.length() = 0 or (path_acc[1] = '/' and path_acc.length() = 1)
        then error('Cannot ascend above path root! path:' || path || ', relbase: ' || relbase)
        else path_acc[:-2]
        end
      else path_acc.list_append(part)
      end
    ),
    []
  )
  .list_aggregate('string_agg', '/')
  .regexp_replace('^//', '/')
;

create function relative_to(path, base) as
  case when path.is_abs() then
    case when path.starts_with(base.abs().normalize_path()) then path[base.abs().strlen() + 1:]
    else error(format('Absolute path `{}` is outside of path root `{}`!', path, base.abs())) end
  else base || '/' || path end
;

set variable duckdb_keywords = (from duckdb_keywords() select list(keyword_name));

create function qualname(qualpath) as
  from_json(qualpath, '["VARCHAR"]')
  .list_transform(lambda name:
    -- https://duckdb.org/docs/lts/sql/dialect/keywords_and_identifiers
    case when
      getvariable('duckdb_keywords').list_contains(name)
      or not name.regexp_matches('^[a-zA-Z]\S+$')
    then
      '"' || name.replace('"', '""') || '"'
    else
      name
    end
  )
  .list_aggregate('string_agg', '.')
;

create function qual_id(filename, qualname) as
  case
  when count(*) over (partition by filename, qualname) > 1 then
    error(
      'Model/source name `' || qualname || '` in file `' || filename || '` is not unique!' || (
        case
        when qualname = getvariable('default_qualname')
        then format(' (Note that bare SQL statements get assigned the name `{}`.)', getvariable('default_qualname'))
        end
      )
    )
  else filename || '#' || qualname
  end
;

create function manifest_sql(ast) as
  case when ast is null then null
  else json_deserialize_sql(
    json_object('statements', json_array(
      case
      when (ast->>'$.type') = 'SELECT_NODE'
      then json_object('node', ast)
      else ast
      end
    ))
  ) end
;

-- BEGIN SQL PARSING

/*
Note: Throughout, stmt_id is a tuple of integers based on the lexical position of a statement within its file or nested
query; eventually, when a model stmt contains ctes, all ctes go under [<...model_stmt_id>, 0, <cte_id>], and the final query
goes under [<...stmt_id>, 1]. this way, `stmt_id` is a topographic (and lexical) ordering of the statements within a
file (helpful since ctes can only refer to previously declared ctes).
*/

create temp table sql_files as (
  from read_text('src/**/*.sql')
  select
    filename.regexp_replace('^src/', '') as filename,
    content
);

create temp table sql_stmts as
  from
    sql_files,
    json_each(
      json_serialize_sql(content)->'$.statements[*]'
    )
  select
    filename,
    [key::integer] as stmt_id,
    value as stmt
;

-- EXTRACT IMPORTS (attach '*.sql' ...)
create temp table sql_imports as
  from sql_stmts
  select
    filename,
    stmt_id,
    stmt->>'$.info.parsed_path.value.value' as imported_rel,
    normalize_path(imported_rel, coalesce(nullif(parse_dirpath(filename), ''), '.')) as imported,
    coalesce(nullif(stmt->>'$.info.name', ''), parse_filename(imported, true)) as alias,
  where
    stmt->>'$.type' = 'ATTACH_STATEMENT' and
    stmt->>'$.info.parsed_path.type' = 'VALUE_CONSTANT' and
    stmt->>'$.info.parsed_path.value.type.id' = 'VARCHAR' and
    imported like '%.sql'
;

create temp table sql_import_validations as
  with

    validate_circular_imports as (
      with recursive
        import_paths as (
          from sql_imports
          select
            [filename, imported] as path,
            imported = filename as is_cycle,
          union all
          select
            path.list_append(imported) as path,
            path.list_contains(imported) as is_cycle,
          from import_paths join sql_imports on import_paths.path[-1] = sql_imports.filename
          where not is_cycle
        ),
        trimmed_cycles as (
          select distinct path[path.list_position(path[-1]):] as path
          from import_paths
          where is_cycle
        )
      from trimmed_cycles
      select path[0], 'Circular import detected: {}'.format(path.array_to_string(' -> '))
    ),

    validate_imports_exist(filename, error_msg) as (
      from sql_imports
      anti join sql_files on sql_imports.imported = sql_files.filename
      select filename, 'Import `{}` (resolved: `{}`) does not exist!'.format(imported_rel, imported)
    ),

    validations(filename, error_msg) as (
      from validate_circular_imports union all
      from validate_imports_exist
    )

  from validations
;

.print
.print Import errors:
from sql_import_validations;
.print
.print Imports:
from sql_imports;
.print

-- remove processed import statements
delete from sql_stmts using sql_imports as parsed where sql_stmts.filename = parsed.filename and sql_stmts.stmt_id = parsed.stmt_id;


-- EXTRACT SOURCE DECLARATIONS (create table (not as))
create temp table sql_sources as
  from sql_stmts
  select
      filename,
      stmt_id,

      (stmt->'$.info.qualified_name.path').qualname() as rel_qualname,
      stmt as rel_ct_ast,

  where
    (stmt->>'$.type') = 'CREATE_STATEMENT' and
    (stmt->>'$.info.type') = 'TABLE_ENTRY' and
    (stmt->'$.info.query') = 'null'
;

-- remove processed source declarations
delete from sql_stmts using sql_sources as parsed where sql_stmts.filename = parsed.filename and sql_stmts.stmt_id = parsed.stmt_id;


-- EXTRACT MODELS ([create table as] select ...)
create temp table sql_models as
  with

    sql_models_toplevel as (

      from sql_stmts
      select
        filename,
        stmt_id.list_append(1) as stmt_id,
        coalesce(stmt->'$.info.qualified_name.path', json_array(getvariable('default_qualname'))) as qualpath,
        qualpath.qualname() as rel_qualname,
        coalesce(stmt->'$.info.query.node', stmt->'$.node') as rel_select_ast,

        json_merge_patch(
          coalesce(
            case when stmt->>'$.type' = 'CREATE_STATEMENT' then stmt end, /* use original "create table" statement if exists */
            json_serialize_sql('create table ' || rel_qualname || ' as from foo')->'$.statements[0]' /* else make a simple one */
          ),
          '{"info":{"query": null}}' /* but always wipe out any "as <select...>" suffix */
        )
        as rel_ct_ast,

      where
        ( /* create table ... as ... */
          (stmt->>'$.type') = 'CREATE_STATEMENT' and
          (stmt->>'$.info.type') = 'TABLE_ENTRY' and
          (stmt->'$.info.query') != 'null'
        )
        or ( /* bare select */
          (stmt->>'$.node.type') = 'SELECT_NODE'
        )
    ),

    /* expand models which contain ctes, recursively. */
    sql_models_with_ctes as (

      with recursive sql_models_with_ctes_impl as (

        /* initial base case */
        from sql_models_toplevel
        select *, null::json as cte_info

        union

        /* recurse into ctes */
        from
          sql_models_with_ctes_impl,
          json_each(rel_select_ast->'$.cte_map.map[*]')
        select
          sql_models_with_ctes_impl.* replace(
            stmt_id[:-2].list_append(0).list_append(key::integer) as stmt_id, /* remove .1 and append .0.<cte_index> to stmt_id */
            rel_qualname || '^' || (value->>'$.key'::text) as rel_qualname, /* append CTE name to qualname */
            value->>'$.value.query_node' as rel_select_ast, /* extract cte query itself */
            json_merge_patch(value->'$.value', json('{"query_node":null}')) as cte_info, /* capture cte ast info (without query) */
          )
      )

      from sql_models_with_ctes_impl
      select * replace (
        /* remove ctes from query asts now since they're fully captured elsewhere */
        json_merge_patch(rel_select_ast, '{"cte_map":{"map":[]}}') as rel_select_ast,
      )
    )

  from sql_models_with_ctes
  order by stmt_id
;

-- remove processed model declarations
delete from sql_stmts using sql_models as parsed where sql_stmts.filename = parsed.filename and sql_stmts.stmt_id = parsed.stmt_id[:1];

create view sql_relations as (
  from (
    from (
      select 'source' as rel_kind, * from sql_sources
      union all by name
      select 'model' as rel_kind, * from sql_models
    )
    select
      *,
      case when rel_select_ast is null then null
      else json_merge_patch(rel_ct_ast, json_object('info', json_object('query', json_object('node', rel_select_ast))))
      end as rel_ctas_ast,
  )

  select
    rel_kind,
    filename.qual_id(rel_qualname) as rel_id,

    columns(lambda c: c not like 'rel_%_ast' and c != 'rel_kind'),

    manifest_sql(columns('^rel_(\w+)_ast$')) as 'rel_\1_sql',

  order by
    filename,
    stmt_id,
);


.print Relations:
from sql_relations;

-- write relation json info into build folder
copy sql_relations to 'build' (
  format json,
  partition_by ('rel_kind', 'rel_id'), write_partition_columns true, overwrite_or_ignore,
  filename_pattern 'rel', file_extension 'json'
);

-- write queries into build folder
copy (

  from (
    unpivot sql_relations
    on columns('rel_.*_sql')
    into name rel_stmt_kind_col value rel_stmt_sql
  )
  select
    rel_kind,
    rel_id,
    rel_stmt_kind_col.regexp_replace('^rel_(\w+)_sql$', '\1') as rel_stmt_kind,
    rel_stmt_sql,

  where
    rel_stmt_sql is not null

  qualify
    count(*) over (partition by rel_kind, rel_id, rel_stmt_kind) = 1
    or error('rel_stmt_kind ' || rel_stmt_kind || ' not unique!')

) to 'build' (
  filename_pattern 'query', file_extension 'sql', partition_by ('rel_kind', 'rel_id', 'rel_stmt_kind'),
  format csv, header false, escape '', quote '', overwrite_or_ignore,
);

-- -- write the actual ninja build
-- create temp table build_rules as
--   from sql_relations
--   left join sql_imports using (filename)
