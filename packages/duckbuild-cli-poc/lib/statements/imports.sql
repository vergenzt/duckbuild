-- EXTRACT IMPORTS (attach '<...>.sql' [as ...])
create table sql_imports as
  from sql_stmts
  select
    filename,
    stmt_id,
    stmt->>'$.info.parsed_path.literal.text' as imported_rel,
    normalize_path(imported_rel, coalesce(nullif(parse_dirpath(filename), ''), '.')) as imported,
    coalesce(nullif(stmt->>'$.info.name', ''), parse_filename(imported, true)) as alias,
  where
    stmt->>'$.type' = 'ATTACH_STATEMENT' and
    stmt->>'$.info.parsed_path.type' = 'VALUE_CONSTANT' and
    stmt->>'$.info.parsed_path.literal.kind' = 'STRING' and
    imported like '%.sql'
;

delete from sql_stmts using sql_imports as parsed where sql_stmts.filename = parsed.filename and sql_stmts.stmt_id = parsed.stmt_id;

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

.mode jsonlines
from sql_import_validations;
from sql_import_validations select error('Import errors!');
.mode duckbox
