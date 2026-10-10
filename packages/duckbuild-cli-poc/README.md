# duckbuild-cli-poc

A SQL-based proof-of-concept for duckbuild SQL compilation.

To use, add this folder to `$PATH`, `cd` to the directory containing `duckbuild.toml` and `src/**.sql`, then run `duckbuild-compile.sql`. Your compiled SQL files should then show up in `build/`.

Example build output generated from the current proof of concept is committed in [`duckbuild-example/build`](../duckbuild-example/build).

## Architecture

`duckbuild-compile.sql` reads SQL source files from `$DUCKBUILD_SRC_PATH` (defaulting to `src` if unset), then uses DuckDB's builtin [`json_serialize_sql` function](https://duckdb.org/docs/current/data/json/sql_to_and_from_json) to parse the SQL statement(s) they contain.

### Statement Kinds

Four key kinds of statements are currently understood:

1. **Bare `SELECT` statements**. These define **main models**.

   There can be at most one main model in each file, and it will be named `main`.

2. **`CREATE TABLE ... AS ...` statements**. These define **named models**.

   There can be multiple named models in a file, and they can be referenced from other models (later in the same file or imported from elsewhere).

   Declaring `CREATE TABLE main AS ...` is equivalent to a bare `SELECT` statement, however `CREATE TABLE main AS ...`  allows you to explicitly declare column names and types (and [eventually, hopefully](https://github.com/duckdb/duckdb/discussions/25917) descriptions) in parentheses after the table name `main`.

   E.g. file `users.sql` could declare `CREATE TABLE main (user_id integer, user_name text, ...) AS ...`.

3. **`CREATE TABLE` statements** (with no `AS ...` query definition clause). These declare **sources** which hold raw data to be read/transformed, not ever derived from other data.

   Sources' contents must be mounted at execution time by environment configuration.

4. **`ATTACH '<...>.sql' [AS <alias>]`**. These *lexically* import other SQL files in order for local models to reference the models or sources they define.

   > [!note]
   >
   > These lexical imports do not ever directly execute in DuckDB; they are *parsed* by `duckbuild` at compile time and affect how table references inside models are resolved to their referees.

   If unspecified, `alias` defaults to the basename of the file, so e.g. `attach '../sources/payments.sql';`  results in models from `sources/payments.sql` referencable locally under `payments.<model_name>`.

### Referring to models

Fully qualified model IDs take the form:

````
<path.to.filename_without_extension>.model_name[~cte_name[...]]
````

That is, it consists of up to three parts:

1. the path to the file containing the model, relative to `$DUCKBUILD_SRC_PATH`, separated by dots instead of slashes, and with the `.sql` suffix removed (e.g. `src/marts/customers.sql` → `marts.customers`);
2. the local name of the top-level model within the file (e.g. `main` for a bare select, otherwise the name from the `CREATE TABLE` statement); and finally
3. a suffix indicating any CTE(s) inside which the model is defined, separated from the top-level model name and from each other by tildes (`~`).

> [!note]
>
> In `duckbuild`, CTEs can be *identified* and *executed* independently of the top-level models which define them, but SQL-level rules for referencing them are unchanged: a CTE can only be referenced by other CTEs defined later in the query or by the top-level query itself.

Each dot- or tilde-separated part above should be quoted as/if needed according to [DuckDB's identifier quoting rules](https://duckdb.org/docs/current/sql/dialect/keywords_and_identifiers).

#### Examples

From the following SQL file:

```
-- filename: src/marts/customers.sql

attach '../staging.sql';

with
  customers as (from staging.stg_customers),
  customer_orders as (
    select
      customer_id,
      min(order_date) as first_order,
      max(order_date) as most_recent_order,
      count(order_id) as number_of_orders
    from staging.stg_orders
    group by customer_id
  ),
  customer_payments as (
    select
      customer_id,
      sum(amount) as total_amount
    from staging.stg_payments
    left join staging.stg_orders using (order_id)
    group by customer_id
  )
select
  customers.customer_id,
  customers.first_name,
  customers.last_name,
  customer_orders.first_order,
  customer_orders.most_recent_order,
  customer_orders.number_of_orders,
  customer_payments.total_amount as customer_lifetime_value
from customers
left join customer_orders using (customer_id)
left join customer_payments using (customer_id)
;
```

There would be the following four model identifiers:

1. `marts.customers.main~customers` (referencing `staging.stg_customers`),
2. `marts.customers.main~customer_orders` (referencing `staging.stg_orders`),
3. `marts.customers.main~customer_payments` (referencing `staging.stg_payments` and `staging.stg_orders`), and
4. `marts.customers.main` (referencing `…~customers`, `…~customer_orders`, and `…~customer_payments`).
