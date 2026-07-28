CREATE TABLE raw_orders(id INTEGER PRIMARY KEY, user_id INTEGER, order_date date, status text, FOREIGN KEY (user_id) REFERENCES raw_customers(id));
