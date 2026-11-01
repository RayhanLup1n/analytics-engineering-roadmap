-- Raw event log for the refund reconciliation case study.
-- Synthetic data (19 orders / 45 events), designed to cover:
--   * normal settled orders
--   * duplicate webhook payloads (network retries)
--   * late-arriving refunds (ingested days after the business event)
--   * cancellations before/after payment
--   * integrity anomalies (orphan refund, over-refund, missing placement event)

DROP TABLE IF EXISTS public.raw_order_events;

CREATE TABLE public.raw_order_events (
    event_id    VARCHAR(50) PRIMARY KEY,
    order_id    INT           NOT NULL,
    customer_id INT           NOT NULL,
    event_type  VARCHAR(30)   NOT NULL, -- ORDERED_PLACED | PAYMENT_CONFIRMED | REFUNDED | CANCELLED
    amount      NUMERIC(12,2) NOT NULL,
    event_time  TIMESTAMP     NOT NULL,
    ingested_at TIMESTAMP     DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_raw_order_events_order_id ON public.raw_order_events (order_id);
