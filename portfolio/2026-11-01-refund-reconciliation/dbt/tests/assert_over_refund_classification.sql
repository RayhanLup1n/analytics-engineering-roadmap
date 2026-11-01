
-- Test 03: Over-Refund Classification
-- Refunded amount must not exceed confirmed payment
-- without being flagged as a financial anomaly.

SELECT
    order_id,
    gross_amount,
    refund_amount,
    has_payment,
    anomaly_reason,
    financial_status
FROM {{ ref('fct_event_orders') }}
WHERE
    has_payment = TRUE
    AND refund_amount > gross_amount
    AND (
        anomaly_reason IS DISTINCT FROM 'OVER_REFUND'
        OR financial_status IS DISTINCT FROM 'DATA_ANOMALY'
    )
