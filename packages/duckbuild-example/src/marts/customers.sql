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
