-- =============================================================================
-- Dallas: date formats and date quality
-- Run: 2026-10-15 / 2026-10-16
-- Informed: date parsing, intake_at / outcome_at, and the date flags in
--           stg_dallas__intakes
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Q1. What do the date and time columns look like? (typos + random sample)
--
-- Result:
--   intake_date   '2025-11-21T00:00:00.000'  -> date in first 10 chars
--   intake_time   '12:38:00'                 -> separate column
--   Typos found:  2920-05-05, 2030-12-31, 2029-06-06, 2027-09-23
--   Some typo rows have outcome_date earlier than intake_date
--     (e.g. intake 2029-06-06, outcome 2020-07-07).
--   outcome_time is '00:00:00' even for animals with no outcome_date.
-- Decision:
--   - parse left(date, 10); combine with time into DATETIME (local, no zone)
--   - flag is_intake_date_implausible (null, < 2010, > snapshot date)
--   - flag is_outcome_before_intake
--   - treat outcome_time '00:00:00' as unknown, not midnight
-- -----------------------------------------------------------------------------
select intake_date, intake_time, outcome_date, outcome_time
from {{ source('raw', 'dallas_current') }}
where cast(intake_date as string) >= '2027'
   or cast(intake_date as string) <  '2010'
   or rand() < 0.0001
limit 30;


-- -----------------------------------------------------------------------------
-- Q2. How many rows does each flag catch?
--
-- Result (160,053 rows):
--   implausible_intake       4      (0.003%)
--   outcome_before_intake    9      (0.006%) <- 5 more than the typo rows
--   still_in_shelter       807
--   outcome_time_unknown 15,889     (~10%; too many to be real midnight exits)
-- Decision: flags kept. The 5 extra rows led to Q3 below.
-- -----------------------------------------------------------------------------
select
    count(*)                                    as total_rows,
    countif(source_table = 'dallas_historical') as historical_rows,
    countif(is_intake_date_implausible)         as implausible_intake,
    countif(is_outcome_before_intake)           as outcome_before_intake,
    countif(outcome_date is null)               as still_in_shelter,
    countif(is_outcome_time_unknown and outcome_date is not null) as outcome_time_unknown
from {{ ref('stg_dallas__intakes') }};


-- -----------------------------------------------------------------------------
-- Q3. What are the rows where outcome is before intake?
--
-- Result: all 9 have outcome_type 'lost exp' or 'found exp'.
--   7 have plausible intake dates (e.g. K24-621157: intake 2025-04-05,
--   outcome 2024-05-07 -> intake year likely mistyped as 2025).
-- Decision: led to the lost/found report investigation (03_record_types.sql).
-- -----------------------------------------------------------------------------
select impound_number, source_table, intake_date, outcome_date, outcome_type,
       is_intake_date_implausible
from {{ ref('stg_dallas__intakes') }}
where is_outcome_before_intake
order by is_intake_date_implausible, intake_date;


-- -----------------------------------------------------------------------------
-- Q4. Are the 807 rows with no outcome recent, or is data missing?
--
-- Result:
--   dallas_historical   0       <- no gaps in older data
--   dallas_current 2024 13, 2025 6, 2026 787, 2027 1 (the 2027-09-23 typo)
-- Decision: open records are genuine. The 19 from 2024-2025 are long stays
--           to watch as outliers in length-of-stay.
-- Note: "rows" is a reserved word in BigQuery, hence row_count.
-- -----------------------------------------------------------------------------
select source_table,
       extract(year from intake_date) as intake_year,
       count(*) as row_count
from {{ ref('stg_dallas__intakes') }}
where outcome_date is null
group by 1, 2
order by 1, 2;