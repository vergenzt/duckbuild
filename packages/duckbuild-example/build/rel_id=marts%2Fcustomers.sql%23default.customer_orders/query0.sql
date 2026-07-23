SELECT customer_id, min(order_date) AS first_order, max(order_date) AS most_recent_order, count(order_id) AS number_of_orders FROM staging.stg_orders GROUP BY customer_id
