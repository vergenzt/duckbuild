#!/usr/bin/env duckdb -f
.once stderr
.print === duckbuild proof of concept ===
.once stderr
.print Run this from the directory containing the SQL files you want to compile.
.once stderr
.print It will produce 'build.ninja' for running them.


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

create function qualname(name_parts) as
  list_aggregate(
    from_json(name_parts, '["VARCHAR"]'),
    'string_agg',
    '.'
  )
;

create function qual_id(filename, qualname) as
  case
  when count(*) over (partition by filename, qualname) > 1 then
    error(
      'Model/source name `' || qualname || '` in file `' || filename || '` is not unique!' || (
        case
        when qualname = 'default'
        then ' (Note that bare SQL statements get assigned the name `default`.)'
        end
      )
    )
  else filename || '#' || qualname
  end
;

-- BEGIN SQL PARSING

create temp table sql_stmts as
  from
    read_text('src/**/*.sql'),
    json_each(
      json_serialize_sql(content)->'$.statements[*]'
    )
  select
    filename.regexp_replace('^src/', '') as filename,

    /* stmt_id is a tuple of integers; eventually, when a model stmt contains ctes, all ctes go under [<...stmt_id>, 0,
    <cte_id>], and the final query goes under [<...stmt_id>, 1]. this way, `stmt_id` is a topographic (and lexical)
    ordering of the statements within a file (helpful since ctes can only refer to previously declared ctes). */
    [key::integer] as stmt_id,

    value as stmt
;


-- EXTRACT IMPORTS (attach '*.sql' ...)
create temp table sql_imports as
  from sql_stmts
  select
    filename,
    stmt_id,

    stmt->>'$.info.parsed_path.value.value' as par_imported,
    normalize_path(par_imported, parse_dirpath(filename)) as res_imported,

    nullif(stmt->>'$.info.name', '') as par_alias,
    coalesce(par_alias, parse_filename(par_imported, true)) as res_alias,

  where
    stmt->>'$.type' = 'ATTACH_STATEMENT' and
    stmt->>'$.info.parsed_path.type' = 'VALUE_CONSTANT' and
    stmt->>'$.info.parsed_path.value.type.id' = 'VARCHAR' and
    par_imported like '%.sql'
;
-- remove processed stmts
delete from sql_stmts using sql_imports as parsed where sql_stmts.filename = parsed.filename and sql_stmts.stmt_id = parsed.stmt_id;


-- EXTRACT SOURCE DECLARATIONS (create table (not as))
create temp table sql_sources as
  from (
    from sql_stmts
    select
        filename,
        stmt_id,

        (stmt->'$.info.qualified_name.path').qualname() as source_qualname,
        stmt as ctas_info,

    where
      (stmt->>'$.type') = 'CREATE_STATEMENT' and
      (stmt->>'$.info.type') = 'TABLE_ENTRY' and
      (stmt->'$.info.query') = 'null'
  )

  select
    filename.qual_id(source_qualname) as source_id,
    *
;

-- remove processed stmts
delete from sql_stmts using sql_sources as parsed where sql_stmts.filename = parsed.filename and sql_stmts.stmt_id = parsed.stmt_id;


-- EXTRACT MODELS ([create table as] select ...)
create temp table sql_models as
  with

    sql_models_toplevel as (

      from sql_stmts
      select
        filename,
        stmt_id.list_append(1) as stmt_id,
        coalesce(stmt->'$.info.qualified_name.path', '["default"]').qualname() as model_qualname,
        coalesce(stmt->'$.info.query.node', stmt->'$.node') as model_query_ast,

        case model_qualname
        when 'default' then null
        else json_merge_patch(stmt, '{"info":{"query": null}}')
        end
        as ctas_info,

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
          json_each(model_query_ast->'$.cte_map.map[*]')
        select
          sql_models_with_ctes_impl.* replace(
            stmt_id[:-2].list_append(0).list_append(key::integer) as stmt_id, /* remove .1 and append .0.<cte_index> to stmt_id */
            model_qualname || '.' || (value->>'$.key'::text) as model_qualname, /* append CTE name to qualname */
            value->>'$.value.query_node' as model_query_ast, /* extract cte query itself */
            json_merge_patch(value->'$.value', json('{"query_node":null}')) as cte_info, /* capture cte ast info (without query) */
          )
      )

      from sql_models_with_ctes_impl
      select * replace (
        /* remove ctes from query asts now since they're fully captured elsewhere */
        json_merge_patch(model_query_ast, '{"cte_map":{"map":[]}}') as model_query_ast,
      )
    )

  from sql_models_with_ctes
  select

    filename.qual_id(model_qualname) as model_id,

    *,

    json_deserialize_sql(json_object('statements', json_array(json_object('node', model_query_ast)))) as model_query_sql,

  order by stmt_id
;
-- remove processed stmts
delete from sql_stmts using sql_models as parsed where sql_stmts.filename = parsed.filename and sql_stmts.stmt_id = parsed.stmt_id;

from sql_models;


-- write model queries into build folder
copy (from sql_models select model_id, model_query_sql) to 'build' (
  format csv, header false, escape '', quote '', overwrite_or_ignore,
  partition_by ('model_id'), filename_pattern 'query', file_extension 'sql',
  return_files true,
);

-- write model query asts into build folder
copy sql_models to 'build' (
  format json,
  partition_by ('model_id'), write_partition_columns true, overwrite_or_ignore,
  filename_pattern 'model', file_extension 'json',
  return_files true,
);



-- -- -- write the actual ninja build
-- -- copy (
-- --   from sql_models
-- --   select
-- --     format('build )

-- -- )
