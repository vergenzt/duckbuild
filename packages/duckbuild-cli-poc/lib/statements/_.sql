/*
Note: Throughout, stmt_id is a tuple of integers based on the lexical position of a statement within its file or nested
query; eventually, when a model stmt contains ctes, all ctes go under [<...model_stmt_id>, 0, <cte_id>], and the final query
goes under [<...stmt_id>, 1]. this way, `stmt_id` is a topographic (and lexical) ordering of the statements within a
file (helpful since ctes can only refer to previously declared ctes).
*/

create table sql_stmts as
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

.read_relative imports.sql
.read_relative sources.sql
.read_relative models.sql
