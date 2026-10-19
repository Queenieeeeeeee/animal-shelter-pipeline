-- =============================================================================
-- Dallas: schema comparison and primary key
-- Run: 2026-10-15, against the 2026-10-14 snapshot
-- Informed: stg_dallas__intakes (UNION of both tables, impound_number as key)
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Q1. Do dallas_current and dallas_historical have the same columns?
--
-- Result: identical. 37 columns in both, all STRING (load.py keeps raw as text).
-- Decision: UNION the two tables. Use an explicit column list rather than
--           SELECT *, because BigQuery UNION matches by position, not name.
-- -----------------------------------------------------------------------------
with cur as (
    select column_name, data_type
    from `{{ source('raw', 'dallas_current').database }}.{{ source('raw', 'dallas_current').schema }}.INFORMATION_SCHEMA.COLUMNS`
    where table_name = 'dallas_current'
),
hist as (
    select column_name, data_type
    from `{{ source('raw', 'dallas_historical').database }}.{{ source('raw', 'dallas_historical').schema }}.INFORMATION_SCHEMA.COLUMNS`
    where table_name = 'dallas_historical'
)
select
    coalesce(cur.column_name, hist.column_name) as column_name,
    cur.data_type  as current_type,
    hist.data_type as historical_type
from cur
full outer join hist using (column_name)
order by (cur.column_name is null or hist.column_name is null) desc, column_name;


-- -----------------------------------------------------------------------------
-- Q2. Which column is unique per row? (latest snapshot only)
--
-- Result (dallas_current):
--   total_rows               125,222
--   distinct_impound_number  125,222   <- unique, 0 nulls
--   distinct_animal_id        93,550   <- ~31,700 re-admissions
--   distinct_activity_number  23,542   <- not a key
-- Decision: impound_number is the primary key (one row per intake).
--           Same grain as Sonoma.
-- -----------------------------------------------------------------------------
with latest as (
    select *
    from {{ source('raw', 'dallas_current') }}
    qualify _snapshot_date = max(_snapshot_date) over ()
)
select
    count(*)                        as total_rows,
    count(distinct animal_id)       as distinct_animal_id,
    count(distinct impound_number)  as distinct_impound_number,
    count(distinct activity_number) as distinct_activity_number,
    countif(impound_number is null) as null_impound_number
from latest;


-- -----------------------------------------------------------------------------
-- Q3. Do the two tables overlap? (The plan expected FY2023 in both.)
--
-- Result: current 125,222 / historical 34,831 / in both 0.
-- Decision: no overlap today. Kept a dedup guard in staging anyway
--           (current wins), and the unique test on the combined model
--           will catch it if Dallas ever republishes overlapping years.
-- -----------------------------------------------------------------------------
with cur as (
    select distinct impound_number
    from {{ source('raw', 'dallas_current') }}
    qualify _snapshot_date = max(_snapshot_date) over ()
),
hist as (
    select distinct impound_number
    from {{ source('raw', 'dallas_historical') }}
    qualify _snapshot_date = max(_snapshot_date) over ()
)
select
    (select count(*) from cur)  as current_count,
    (select count(*) from hist) as historical_count,
    (select count(*) from cur join hist using (impound_number)) as in_both;