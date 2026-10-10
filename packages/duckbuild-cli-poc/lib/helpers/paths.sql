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
