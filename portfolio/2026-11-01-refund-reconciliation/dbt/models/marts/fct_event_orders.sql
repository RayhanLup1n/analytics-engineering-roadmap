{{ config(
    materialized='incremental',
    unique_key='order_id'
) }}

WITH fct_order_financial_reconciliation AS (
	-- 3rd Layer: Financial Reconciliation Mart
	select
		v.order_id,
		v.customer_id,

		-- Financial Metrics
		v.gross_amount,
		v.refund_amount,

		(
			v.gross_amount - v.refund_amount
		) AS net_realized_revenue,

		-- Lifecycle Timestamps
		v.placed_at,
		v.paid_at,
		v.refunded_at,
		v.cancelled_at,

		-- Refund Duration
		v.refund_lead_days,

		-- Lifecycle Flags
		v.has_payment,
		v.has_refund,
		v.has_cancellation,

		        -- Financial integrity
			(
				v.anomaly_reason IS NOT NULL
			) AS has_financial_anomaly,

			(
            			v.anomaly_reason IS NULL
        		) AS is_valid_financial_record,

		        v.anomaly_reason,

		        -- Financial status
        		CASE
            			WHEN v.anomaly_reason IS NOT NULL
            			THEN 'DATA_ANOMALY'

				WHEN v.has_cancellation = TRUE
				AND v.has_payment = FALSE
				THEN 'CANCELLED_UNPAID'

				WHEN v.gross_amount > 0
				AND v.refund_amount = v.gross_amount
				THEN 'FULLY_REFUNDED'

				WHEN v.has_cancellation = TRUE
				AND v.has_payment = TRUE
				THEN 'CANCELLED_PAID_REVIEW'

				WHEN v.gross_amount > 0
				AND v.refund_amount > 0
				AND v.refund_amount < v.gross_amount
				THEN 'PARTIALLY_REFUNDED'

				WHEN v.gross_amount > 0
				THEN 'SETTLED_NET'

				ELSE 'PENDING_UNPAID'
        		END AS financial_status,

		        -- Latest business event timestamp
        		GREATEST(
            			v.placed_at,
            			v.paid_at,
            			v.refunded_at,
            			v.cancelled_at
        		) AS watermark_updated_at,

		        -- Latest data ingestion timestamp
        		v.last_ingested_at
	FROM {{ ref('int_event_orders') }} v

	{% if is_incremental() %}
	WHERE v.last_ingested_at >= (
		SELECT COALESCE(
			MAX(last_ingested_at),
			TIMESTAMP '1900-01-01'
		)
		FROM {{ this }}
	)
	{% endif %}
)
SELECT
    *
FROM fct_order_financial_reconciliation

