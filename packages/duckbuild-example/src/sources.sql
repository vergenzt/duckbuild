create table raw_customers (
  id integer primary key,
  first_name text,
  last_name text,
);

create table raw_orders (
  id integer primary key,
  user_id integer,
  order_date date,
  status text,
  foreign key (user_id) references raw_customers(id),
);

create table raw_payments (
  id integer primary key,
  order_id integer,
  payment_method text,
  amount_cents integer,
  foreign key (order_id) references raw_orders(id),
);
