# This file is included by DuckDB's build system. It specifies which extension to load

# Extension from this repo
duckdb_extension_load(duckdb_macros
    SOURCE_DIR ${CMAKE_CURRENT_LIST_DIR}
    EXTENSION_VERSION v0.0.1
)

# json is needed to exercise json_serialize_sql (the macro parse -> AST -> JSON path)
duckdb_extension_load(json)