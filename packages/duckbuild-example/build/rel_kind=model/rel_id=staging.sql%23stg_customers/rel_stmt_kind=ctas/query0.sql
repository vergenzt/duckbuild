CREATE TEMP TABLE stg_customers AS SELECT id AS customer_id, first_name, last_name FROM sources.raw_customers
