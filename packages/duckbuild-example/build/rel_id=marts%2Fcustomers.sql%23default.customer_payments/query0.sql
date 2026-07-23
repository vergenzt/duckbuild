SELECT customer_id, sum(amount) AS total_amount FROM (staging.stg_payments LEFT JOIN staging.stg_orders USING (order_id)) GROUP BY customer_id
