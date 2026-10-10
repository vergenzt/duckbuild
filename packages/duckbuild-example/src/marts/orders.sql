attach '../staging.sql';

with

  orders as (from staging.stg_orders),

  order_payment_methods as (
    /* see https://duckdb.org/docs/current/sql/statements/pivot. (note: resulting columns are "<payment_method>_amount".) */
    pivot staging.stg_payments
    on payment_method in ('credit_card', 'coupon', 'bank_transfer', 'gift_card')
    using sum(amount) as amount
    group by order_id
  ),

  order_payments as (
    select
      order_id,
      sum(amount) as amount,
    from staging.stg_payments
    group by order_id
  ),

select
  order_id,
  customer_id,
  order_date,
  status,
  columns('.*_total'),
  amount,

from orders
left join order_payment_methods using (order_id)
left join order_payments using (order_id)
