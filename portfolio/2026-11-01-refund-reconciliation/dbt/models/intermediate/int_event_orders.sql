{{ config(materialized='ephemeral') }}

WITH staging_layer AS (
	SELECT * FROM {{ ref('stg_event_orders') }}
),
int_event_orders AS (
	-- 2nd (A) Layer (intermediate layer): Summary of lifecycle per order
	SELECT
		stg.order_id,
		stg.customer_id,

		-- Financial Aggregation
		SUM(CASE
			WHEN stg.event_type = 'PAYMENT_CONFIRMED'
			THEN stg.amount
			ELSE 0
			END
		) as gross_amount,

		SUM(CASE
			WHEN stg.event_type = 'REFUNDED'
			THEN stg.amount
			ELSE 0
			END
		) as refund_amount,

		-- Lifecycle Timestamps
		MAX(CASE
			WHEN stg.event_type = 'ORDERED_PLACED'
			THEN stg.event_time
			ELSE NULL
			END
		) as placed_at,

		MAX(CASE
			WHEN stg.event_type = 'PAYMENT_CONFIRMED'
			THEN stg.event_time
			ELSE NULL
			END
		) as paid_at,

		MAX(CASE
			WHEN stg.event_type = 'REFUNDED'
			THEN stg.event_time
			ELSE NULL
			END
		) as refunded_at,

		MAX(CASE
			WHEN stg.event_type = 'CANCELLED'
			THEN stg.event_time
			ELSE NULL
			END
		) as cancelled_at,

		-- Lifecycle Flags
		BOOL_OR(
			stg.event_type = 'PAYMENT_CONFIRMED'
		) as has_payment,

		BOOL_OR(
			stg.event_type = 'REFUNDED'
		) as has_refund,

		BOOL_OR(
			stg.event_type = 'CANCELLED'
		) as has_cancellation,

		-- Latest Ingestion Timestamp per order
		MAX(stg.ingested_at) AS last_ingested_at

	FROM staging_layer stg
	GROUP BY 
		stg.order_id,
		stg.customer_id
),
int_refund_days as (
	-- 2nd (B) Layer: Refund Lead Time
	SELECT
		it.*,

		CASE
			WHEN it.paid_at IS NOT NULL
			AND it.refunded_at IS NOT NULL
			THEN ROUND(
				(
					EXTRACT(EPOCH FROM it.refunded_at)
					- EXTRACT(EPOCH FROM it.paid_at)
				) / 86400.0,
				2
			)
			ELSE NULL
			END as refund_lead_days
	FROM int_event_orders it
),
int_financial_validation AS (
		-- 2nd (C) Layer: Anomaly Detection
	SELECT
		rd.*,

		CASE
			-- Refund Without Payment
			WHEN rd.has_refund = TRUE
			AND rd.has_payment = FALSE
			THEN 'ORPHAN_REFUND'

			-- Refund Amount More Thank Gross Amount
			WHEN rd.refund_amount > rd.gross_amount
			THEN 'OVER_REFUND'

			-- There's no Event Order Eventhough The Payment is Exists
			WHEN rd.has_payment = TRUE
			AND rd.placed_at IS NULL
			THEN 'MISSING_ORDER_PLACED_EVENT'

			-- Payment is Exists Before the Order has built
			WHEN rd.paid_at IS NOT NULL
			AND rd.placed_at IS NOT NULL
			AND rd.paid_at < rd.placed_at
			THEN 'PAYMENT_BEFORE_ORDER'

			-- Refund before Payment
			WHEN rd.refunded_at IS NOT NULL
			AND rd.paid_at IS NOT NULL
			AND rd.refunded_at < rd.paid_at
			THEN 'REFUND_BEFORE_PAYMENT'

			-- Paymet After Cancellation
			WHEN rd.paid_at IS NOT NULL
			AND rd.cancelled_at IS NOT NULL
			AND rd.paid_at > rd.cancelled_at
			THEN 'PAYMENT_AFTER_CANCELLATION'

			ELSE NULL
		END AS anomaly_reason
	FROM int_refund_days rd
)
SELECT * FROM int_financial_validation
