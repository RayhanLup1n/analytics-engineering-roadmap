
-- Test 04: Financial Status Consistency
-- Financial status must match business rules.

WITH expected_status AS (
    SELECT
        order_id,
        gross_amount,
        refund_amount,
        has_payment,
        has_refund,
        has_cancellation,
        anomaly_reason,
        financial_status,
        has_financial_anomaly,
        is_valid_financial_record,

        CASE
            WHEN anomaly_reason IS NOT NULL
            THEN 'DATA_ANOMALY'

            WHEN has_cancellation = TRUE
             AND has_payment = FALSE
            THEN 'CANCELLED_UNPAID'

            WHEN gross_amount > 0
             AND refund_amount = gross_amount
            THEN 'FULLY_REFUNDED'

            WHEN has_cancellation = TRUE
             AND has_payment = TRUE
            THEN 'CANCELLED_PAID_REVIEW'

            WHEN gross_amount > 0
             AND refund_amount > 0
             AND refund_amount < gross_amount
            THEN 'PARTIALLY_REFUNDED'

            WHEN gross_amount > 0
            THEN 'SETTLED_NET'

            ELSE 'PENDING_UNPAID'
        END AS expected_financial_status

    FROM {{ ref('fct_event_orders') }}
)

SELECT
    order_id,
    gross_amount,
    refund_amount,
    financial_status,
    expected_financial_status,
    anomaly_reason
FROM expected_status
WHERE
    financial_status
        IS DISTINCT FROM expected_financial_status

    OR has_financial_anomaly
        IS DISTINCT FROM (anomaly_reason IS NOT NULL)

    OR is_valid_financial_record
        IS DISTINCT FROM (anomaly_reason IS NULL)
