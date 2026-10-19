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
-- Q2. How many snapshots does the staging model hold, and how many rows each?
--
-- stg_sonoma__intakes keeps EVERY snapshot (one row per impound per snapshot),
-- so intake_id alone is not unique there. The primary key is
-- snapshot_record_id = intake_id | snapshot_date.
-- Result: not recorded at the time. Run before relying on snapshot counts.
-- -----------------------------------------------------------------------------
select snapshot_date,
       count(*)                  as row_count,
       count(distinct intake_id) as distinct_intakes
from {{ ref('stg_sonoma__intakes') }}
group by 1
order by 1;