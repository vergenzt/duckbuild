SELECT order_id, sum(amount) AS amount FROM staging.stg_payments GROUP BY order_id
