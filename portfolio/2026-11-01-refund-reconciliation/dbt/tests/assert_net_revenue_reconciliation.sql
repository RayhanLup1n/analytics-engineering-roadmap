SELECT
    order_id,
    gross_amount,
    refund_amount,
    net_realized_revenue
FROM {{ ref('fct_event_orders') }}
WHERE net_realized_revenue
    IS DISTINCT FROM (gross_amount - refund_amount)
