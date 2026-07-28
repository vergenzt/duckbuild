CREATE TABLE raw_payments(id INTEGER PRIMARY KEY, order_id INTEGER, payment_method text, amount_cents INTEGER, FOREIGN KEY (order_id) REFERENCES raw_orders(id));
