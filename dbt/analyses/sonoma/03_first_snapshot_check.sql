-- =============================================================================
-- Sonoma: is the 2026-10-01 snapshot complete?
-- Status: OPEN -- not yet run.
--
-- The 2026-10-01 snapshot was pulled by the old extractor, which paged by
-- intake_date. Rows sharing a date could be duplicated or skipped across page
-- boundaries. Later snapshots page by Socrata's :id and are verified against
-- the portal's row count.
-- Decision recorded at the time: handle in staging, do not re-pull.
-- This query measures whether there is anything to handle.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Q1. Duplicates inside each snapshot
--
-- Expected: rows = distinct_intakes for every snapshot after 10-01.
-- Result: (fill in)
-- -----------------------------------------------------------------------------
select _snapshot_date,
       count(*)                       as row_count,
       count(distinct impound_number) as distinct_intakes,
       count(*) - count(distinct impound_number) as duplicate_rows
from {{ source('raw', 'sonoma') }}
group by 1
order by 1;


-- -----------------------------------------------------------------------------
-- Q2. Intakes in a later snapshot that the 10-01 snapshot missed
--
-- Only intakes dated before 2026-10-01 are fair to compare.
-- Result: (fill in)
-- -----------------------------------------------------------------------------
with first_snap as (
    select distinct impound_number
    from {{ source('raw', 'sonoma') }}
    where _snapshot_date = date '2026-10-01'
),
later_snap as (
    select distinct impound_number
    from {{ source('raw', 'sonoma') }}
    where _snapshot_date = (select max(_snapshot_date) from {{ source('raw', 'sonoma') }})
      and date(safe_cast(intake_date as datetime)) < date '2026-10-01'
)
select count(*) as missing_from_first_snapshot
from later_snap
left join first_snap using (impound_number)
where first_snap.impound_number is null;