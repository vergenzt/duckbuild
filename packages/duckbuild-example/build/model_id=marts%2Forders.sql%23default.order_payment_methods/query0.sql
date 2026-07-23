SELECT * FROM staging.stg_payments PIVOT (sum(amount) AS amount FOR (payment_method) IN ('credit_card', 'coupon', 'bank_transfer', 'gift_card') GROUP BY order_id)
