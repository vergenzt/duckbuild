# duckbuild

Generic data build tool / SQL orchestrator based on DuckDB's SQL parser (from "DuckDB build tool").

## Vision

- fast
- lexical/AST-based/hygienic macros a la Rust (not text-based like Jinja)
- explicitly import file paths (e.g. for upstream model or UDF references) -- no global parse phase required
- just support DuckDB (and let it liaise with other DBs if needed)

## Proof of concept

See [packages/duckbuild-cli-poc](./packages/duckbuild-cli-poc)!
