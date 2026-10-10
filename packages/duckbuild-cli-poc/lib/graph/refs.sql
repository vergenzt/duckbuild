create temp table sql_table_refs as
  from
    sql_models,
    (from json_tree(rel_select_ast) where (value->>'type') = 'BASE_TABLE') as rel_table_refs
  select
    rel_id,
    rel_table_refs.fullkey as rel_table_ref_path,
    quoted(rel_table_refs.value->>'table_name') as ref_table_name,
    quoted(nullif(rel_table_refs.value->>'schema_name', '')) as ref_schema_name,
  where
    nullif(rel_table_refs.value->>'catalog_name', '') is null
    or error(format('Model `{}` refers to a catalog `{}`! Table references must be either plain names or `<attached_sql_file>.<model_name>`.', rel_id, rel_table_refs.value->>'catalog_name'))
;

create table sql_refs_in_file as (
  from
    sql_models
    join sql_table_refs using (rel_id)
    join sql_relations on list_bool_and([
      sql_table_refs.ref_schema_name is null,
      sql_table_refs.ref_table_name = sql_relations.rel_name,
      sql_relations.filename = sql_models.filename,
      sql_relations.rel_scope.list_resize(sql_models.rel_scope.len()) = sql_models.rel_scope,
      sql_relations.stmt_id < sql_models.stmt_id,
    ])
  select
    sql_models.rel_id,
    sql_relations.rel_id as ref_id,
    sql_relations.rel_kind as ref_kind,
    sql_table_refs.* except (rel_id)
  qualify
    1 = row_number() over (
      partition by sql_models.rel_id, rel_table_ref_path
      order by sql_relations.stmt_id desc
    )
);

create table sql_refs_imported as (

  from
    sql_models
    join sql_table_refs using (rel_id)
    join sql_imports on list_bool_and([
      sql_imports.alias = sql_table_refs.ref_schema_name,
      sql_imports.filename = sql_models.filename,
      sql_imports.stmt_id < sql_models.stmt_id,
    ])
    join sql_relations on
      sql_relations.rel_scope = [
        sql_imports.imported, -- must reside in imported file
        sql_table_refs.ref_table_name, -- at top scope
      ]

  select
    sql_models.rel_id,
    sql_relations.rel_id as ref_id,
    sql_relations.rel_kind as ref_kind,
    sql_table_refs.* except (rel_id),
    sql_imports.stmt_id as import_stmt_id,

  qualify
    1 = row_number() over (
      partition by sql_models.rel_id, rel_table_ref_path
      order by sql_imports.stmt_id desc
    )
);

create table sql_refs as
  from (
    from sql_refs_in_file
    union all by name
    from sql_refs_imported
  )
  order by rel_id
;
