{{	config(materialized='view')	}}

WITH source as (
	-- 1st Layer: Identify duplicate event

	SELECT
		ev.*,
		ROW_NUMBER() OVER(
			PARTITION BY
				ev.order_id,
				ev.customer_id,
				ev.event_type,
				ev.amount,
				ev.event_time
			ORDER BY
				ev.ingested_at ASC NULLS LAST,
				ev.event_id ASC
		) as rn
	FROM {{ source('public','raw_order_events') }} ev
),
stg_event_orders AS(
	-- Hold the first event as the right event (remove the others)
	SELECT
		s.event_id,
		s.order_id,
		s.customer_id,
		s.event_type,
		s.amount,
		s.event_time,
		s.ingested_at
	FROM source s
	WHERE s.rn = 1
)
SELECT stg.* FROM stg_event_orders stg
