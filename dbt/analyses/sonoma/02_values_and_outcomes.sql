-- =============================================================================
-- Sonoma: value casing, open records, outcome types
-- Run: 2026-10-15
-- Informed: lower() on every categorical column in stg_sonoma__intakes
--
-- Note: queries reconstructed on 2026-10-19 from the results recorded in the
-- progress log. Results are the original figures.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Q1. What casing do Sonoma's categorical values use?
--
-- Result: ALL CAPS ('DOG', 'ADOPTION'), the same as Dallas.
--         The README table showing 'Dog' / 'Stray' is wrong (to fix).
-- Decision: lowercase every categorical column in staging, as in Dallas.
-- -----------------------------------------------------------------------------
with latest as (
    select *
    from {{ source('raw', 'sonoma') }}
    qualify _snapshot_date = max(_snapshot_date) over ()
)
select type, intake_type, outcome_type, count(*) as row_count
from latest
group by 1, 2, 3
order by row_count desc
limit 20;


-- -----------------------------------------------------------------------------
-- Q2. How many records have no outcome yet?
--
-- Result: 227 rows with no outcome_date (latest snapshot).
-- Decision: genuine open stays; length of stay will be null for these
--           until they leave. Not flagged as an error.
-- -----------------------------------------------------------------------------
select
    count(*)                      as total_rows,
    countif(outcome_date is null) as no_outcome_date
from {{ ref('stg_sonoma__intakes') }}

-- -----------------------------------------------------------------------------
-- Q3. What outcome types exist?
--
-- Result (latest snapshot):
--   return to owner   11,251
--   adoption           9,741
--   transfer           7,581
--   euthanize          4,834
--   plus small counts of disposal, died, rtos, shelter, ...
-- Decision: input to the shared outcome mapping seed (next step).
--           Note Sonoma 'return to owner' vs Dallas 'returned to owner',
--           Sonoma 'euthanize' vs Dallas 'euthanized'.
-- -----------------------------------------------------------------------------
select outcome_type, count(*) as row_count
from {{ ref('stg_sonoma__intakes') }}
group by 1
order by row_count desc;