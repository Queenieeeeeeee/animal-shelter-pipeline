-- =============================================================================
-- Sonoma: primary key and grain
-- Run: 2026-10-15, against the 2026-10-14 snapshot
-- Informed: stg_sonoma__intakes (impound_number -> intake_id,
--           id -> animal_id, snapshot_record_id as primary key)
--
-- Note: queries reconstructed on 2026-10-19 from the results recorded in the
-- progress log. Results are the original figures.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Q1. Which column is unique per intake?
--
-- Result (latest snapshot):
--   total_rows               34,492
--   distinct_impound_number  34,492   <- unique, 0 duplicates
--   distinct_id              30,919   <- animal id, ~3,500 re-admissions
-- Decision: impound_number is one stay (renamed intake_id). id is the animal
--           (renamed animal_id). Same grain as Dallas impound_number.
-- -----------------------------------------------------------------------------
with latest as (
    select *
    from {{ source('raw', 'sonoma') }}
    qualify _snapshot_date = max(_snapshot_date) over ()
)
select
    count(*)                        as total_rows,
    count(distinct impound_number)  as distinct_impound_number,
    count(distinct id)              as distinct_id,
    countif(impound_number is null) as null_impound_number
from latest;


-- -----------------------------------------------------------------------------
-- Q2. How many snapshots does raw hold, and does staging keep all of them?
--
-- Run: 2026-10-19
-- Result (raw):
--   2026-10-01  34,388
--   2026-10-14  34,492
--   stg_sonoma__intakes held both snapshots (68,880 rows), so any count taken
--   on staging without a snapshot filter was roughly doubled. Found when
--   outcome counts came out ~2x the figures recorded on 2026-10-15.
-- Decision: staging keeps the latest snapshot only, matching Dallas.
--           Earlier snapshots stay in raw and feed the SCD2 model later.
--           After the fix: stg_sonoma__intakes = 34,492 rows.
-- -----------------------------------------------------------------------------
select _snapshot_date, count(*) as row_count
from {{ source('raw', 'sonoma') }}
group by 1
order by 1;