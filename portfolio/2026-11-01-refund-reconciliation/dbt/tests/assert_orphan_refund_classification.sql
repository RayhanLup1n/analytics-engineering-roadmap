
-- Test 02: Orphan Refund Classification
-- Refund without payment must be flagged as an anomaly.

SELECT
    order_id,
    gross_amount,
    refund_amount,
    has_payment,
    has_refund,
    anomaly_reason,
    financial_status
FROM {{ ref('fct_event_orders') }}
WHERE
    has_payment = FALSE
    AND has_refund = TRUE
    AND (
        anomaly_reason IS DISTINCT FROM 'ORPHAN_REFUND'
        OR financial_status IS DISTINCT FROM 'DATA_ANOMALY'
    )
