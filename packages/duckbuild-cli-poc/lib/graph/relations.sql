create table sql_relations as
  (from sql_models select 'model' as rel_kind, *)
  union all by name
  (from sql_sources select 'source' as rel_kind, *)
;
