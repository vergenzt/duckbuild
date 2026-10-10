select getvariable('src_dir');

create table sql_files as (
  from read_text(getvariable('src_dir') || '/**/*.sql')
  select
    filename.regexp_replace('^' || regexp_escape(getvariable('src_dir')) || '/', '') as filename,
    content
);
