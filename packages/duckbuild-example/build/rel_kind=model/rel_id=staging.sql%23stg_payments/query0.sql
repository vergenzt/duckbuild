SELECT id AS payment_id, order_id, payment_method, (amount / 100) AS amount FROM sources.raw_payments
