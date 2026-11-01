/*
    Refund Reconciliation Mart — standalone 3-layer SQL
    Target: PostgreSQL 16

    Why this exists
    ---------------
    A GMV report built as `SELECT SUM(amount) ... WHERE status = 'PAID'` overstates
    revenue, because refunds arrive days after the payment (late-arriving events) and
    payment webhooks are retried (duplicate events). This script rebuilds the order
    lifecycle before any money is reported.

    Layers
    ------
    1. stg_event_orders        — deduplicate webhook retries, keep one row per event
    2. int_event_orders        — rebuild the lifecycle per order (placed/paid/refunded/cancelled),
                                 calculate refund lead time, classify anomalies
    3. fct_order_financial_reconciliation — net realized revenue + financial status per order

    Note: the dbt project in ./dbt is the source of truth for this logic.
*/

WITH raw AS (
    -- LAYER 1: identify duplicated webhook payloads
    SELECT
        ev.*,
        ROW_NUMBER() OVER (
            PARTITION BY
                ev.order_id,
                ev.customer_id,
                ev.event_type,
                ev.amount,
                ev.event_time
            ORDER BY
                ev.ingested_at ASC NULLS LAST,
                ev.event_id ASC
        ) AS rn
    FROM public.raw_order_events ev
),

stg_event_orders AS (
    -- keep only the first ingested copy of each event
    SELECT
        r.event_id,
        r.order_id,
        r.customer_id,
        r.event_type,
        r.amount,
        r.event_time,
        r.ingested_at
    FROM raw r
    WHERE r.rn = 1
),

int_event_orders AS (
    -- LAYER 2A: lifecycle summary per order
    SELECT
        stg.order_id,
        stg.customer_id,

        SUM(CASE WHEN stg.event_type = 'PAYMENT_CONFIRMED' THEN stg.amount ELSE 0 END) AS gross_amount,
        SUM(CASE WHEN stg.event_type = 'REFUNDED'          THEN stg.amount ELSE 0 END) AS refund_amount,

        MAX(CASE WHEN stg.event_type = 'ORDERED_PLACED'     THEN stg.event_time END) AS placed_at,
        MAX(CASE WHEN stg.event_type = 'PAYMENT_CONFIRMED'  THEN stg.event_time END) AS paid_at,
        MAX(CASE WHEN stg.event_type = 'REFUNDED'           THEN stg.event_time END) AS refunded_at,
        MAX(CASE WHEN stg.event_type = 'CANCELLED'          THEN stg.event_time END) AS cancelled_at,

        BOOL_OR(stg.event_type = 'PAYMENT_CONFIRMED') AS has_payment,
        BOOL_OR(stg.event_type = 'REFUNDED')          AS has_refund,
        BOOL_OR(stg.event_type = 'CANCELLED')         AS has_cancellation,

        MAX(stg.ingested_at) AS last_ingested_at

    FROM stg_event_orders stg
    GROUP BY
        stg.order_id,
        stg.customer_id
),

int_refund_days AS (
    -- LAYER 2B: how many days a customer held the goods before the refund
    SELECT
        it.*,
        CASE
            WHEN it.paid_at IS NOT NULL AND it.refunded_at IS NOT NULL
            THEN ROUND(
                (EXTRACT(EPOCH FROM it.refunded_at) - EXTRACT(EPOCH FROM it.paid_at)) / 86400.0,
                2
            )
            ELSE NULL
        END AS refund_lead_days
    FROM int_event_orders it
),

int_financial_validation AS (
    -- LAYER 2C: integrity checks, ordered from the most severe to the least
    SELECT
        rd.*,
        CASE
            WHEN rd.has_refund = TRUE AND rd.has_payment = FALSE
                THEN 'ORPHAN_REFUND'

            WHEN rd.refund_amount > rd.gross_amount
                THEN 'OVER_REFUND'

            WHEN rd.has_payment = TRUE AND rd.placed_at IS NULL
                THEN 'MISSING_ORDER_PLACED_EVENT'

            WHEN rd.paid_at IS NOT NULL AND rd.cancelled_at IS NOT NULL
                 AND rd.paid_at > rd.cancelled_at
                THEN 'PAYMENT_AFTER_CANCELLATION'

            WHEN rd.paid_at IS NOT NULL AND rd.placed_at IS NOT NULL
                 AND rd.paid_at < rd.placed_at
                THEN 'PAYMENT_BEFORE_ORDER'

            WHEN rd.refunded_at IS NOT NULL AND rd.paid_at IS NOT NULL
                 AND rd.refunded_at < rd.paid_at
                THEN 'REFUND_BEFORE_PAYMENT'

            ELSE NULL
        END AS anomaly_reason
    FROM int_refund_days rd
),

fct_order_financial_reconciliation AS (
    -- LAYER 3: reconciliation mart
    SELECT
        v.order_id,
        v.customer_id,

        v.gross_amount,
        v.refund_amount,
        (v.gross_amount - v.refund_amount) AS net_realized_revenue,

        v.placed_at,
        v.paid_at,
        v.refunded_at,
        v.cancelled_at,
        v.refund_lead_days,

        v.has_payment,
        v.has_refund,
        v.has_cancellation,

        (v.anomaly_reason IS NOT NULL) AS has_financial_anomaly,
        (v.anomaly_reason IS NULL)     AS is_valid_financial_record,
        v.anomaly_reason,

        CASE
            WHEN v.anomaly_reason IS NOT NULL
                THEN 'DATA_ANOMALY'

            WHEN v.has_cancellation = TRUE AND v.has_payment = FALSE
                THEN 'CANCELLED_UNPAID'

            WHEN v.gross_amount > 0 AND v.refund_amount = v.gross_amount
                THEN 'FULLY_REFUNDED'

            WHEN v.has_cancellation = TRUE AND v.has_payment = TRUE
                THEN 'CANCELLED_PAID_REVIEW'

            WHEN v.gross_amount > 0 AND v.refund_amount > 0 AND v.refund_amount < v.gross_amount
                THEN 'PARTIALLY_REFUNDED'

            WHEN v.gross_amount > 0
                THEN 'SETTLED_NET'

            ELSE 'PENDING_UNPAID'
        END AS financial_status,

        -- watermark for an incremental model
        GREATEST(v.placed_at, v.paid_at, v.refunded_at, v.cancelled_at) AS watermark_updated_at,
        v.last_ingested_at

    FROM int_financial_validation v
)

SELECT *
FROM fct_order_financial_reconciliation
ORDER BY order_id;
