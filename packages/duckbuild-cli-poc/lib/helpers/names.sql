set variable duckdb_keywords = (from duckdb_keywords() select list(keyword_name));

create function quoted(name) as
  -- https://duckdb.org/docs/lts/sql/dialect/keywords_and_identifiers
  case when
    getvariable('duckdb_keywords').list_contains(name)
    or not name.regexp_matches('^[a-zA-Z]\S+$')
  then
    '"' || name.replace('"', '""') || '"'
  else
    name
  end
;

create function rel_id(filename, rel_name) as
  case
  when count(*) over (partition by filename, rel_name) > 1 then
    error(
      'Model/source name `' || rel_name || '` in file `' || filename || '` is not unique!' || (
        case
        when rel_name = getvariable('default_rel_name')
        then format(' (Note that bare SQL statements get assigned the name `{}`.)', getvariable('default_rel_name'))
        end
      )
    )
  else
    filename
    .regexp_replace('\.sql$', '')
    .parse_path()
    .apply(lambda part: quoted(part))
    .list_append(rel_name)
    .array_to_string('.')
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
