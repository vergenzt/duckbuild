attach './sources.sql' as sources;

create temp table stg_customers as
  from sources.raw_customers
  select
    id as customer_id,
    first_name,
    last_name,
;

create temp table stg_orders as
  from sources.raw_orders
  select
    id as order_id,
    user_id as customer_id,
    order_date,
    status,
;

create temp table stg_payments as
  from sources.raw_payments
  select
    id as payment_id,
    order_id,
    payment_method,

    -- `amount` is currently stored in cents, so we convert it to dollars
    amount / 100 as amount,
;
