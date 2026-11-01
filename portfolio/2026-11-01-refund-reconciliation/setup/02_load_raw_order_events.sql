-- Load the synthetic event feed (45 events / 19 orders).
-- Run from this directory so the relative path resolves:
--   psql -d analytics_dw -f 02_load_raw_order_events.sql

\copy public.raw_order_events (event_id, order_id, customer_id, event_type, amount, event_time, ingested_at) FROM 'raw_order_events.csv' WITH (FORMAT csv, HEADER true)
