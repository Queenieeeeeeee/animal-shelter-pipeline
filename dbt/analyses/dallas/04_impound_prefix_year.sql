-- =============================================================================
-- Dallas: can the impound number prefix validate intake year?
-- Run: 2026-10-16
-- Outcome: TESTED AND NOT ADOPTED as a quality rule.
--          Kept as the informational column impound_prefix_year.
--
-- Hypothesis: K24-621157 -> 2024. If the prefix always equals the intake year,
-- a mismatch would expose mistyped years that look plausible on their own
-- (intake 2025-04-05 under a K24 number).
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Q1. How often does the prefix match the intake year?
--
-- Result (160,053 rows):
--   no_prefix                    0
--   same_year              159,035   (99.36%)
--   looks_like_fiscal_year     615   (Oct-Dec intake, prefix = next year)
--   mismatch                 1,017
-- Decision: high agreement, but check the pattern of mismatches before
--           turning this into a rule (Q2).
-- -----------------------------------------------------------------------------
with t as (
    select
        impound_number,
        2000 + safe_cast(regexp_extract(impound_number, r'^[A-Z](\d{2})-') as int64) as prefix_year,
        extract(year  from intake_date) as intake_year,
        extract(month from intake_date) as intake_month
    from {{ ref('stg_dallas__intakes') }}
)
select
    count(*)                                                      as total,
    countif(prefix_year is null)                                  as no_prefix,
    countif(prefix_year = intake_year)                            as same_year,
    countif(prefix_year = intake_year + 1 and intake_month >= 10) as looks_like_fiscal_year,
    countif(prefix_year != intake_year)                           as mismatch
from t;


-- -----------------------------------------------------------------------------
-- Q2. Are mismatches random typos, or systematic?
--
-- Result (top rows):
--   2024-11  +1  223
--   2026-01  -1   95   <- prefix still K25 into January 2026
--   2022-12  +1   90
--   2023-12  +1   80
--   ... plus a steady trickle of +1 across May-Aug (not fiscal-year months)
-- Decision: NOT ADOPTED. Mismatches are almost all +1 and cluster around year
--           boundaries -- system numbering behaviour, not data entry errors.
--           A flag would mislabel most of the 1,017 rows.
-- -----------------------------------------------------------------------------
with t as (
    select
        2000 + safe_cast(regexp_extract(impound_number, r'^[A-Z](\d{2})-') as int64) as prefix_year,
        intake_date
    from {{ ref('stg_dallas__intakes') }}
)
select
    extract(year  from intake_date)              as intake_year,
    extract(month from intake_date)              as intake_month,
    prefix_year - extract(year from intake_date) as year_diff,
    count(*) as row_count
from t
where prefix_year != extract(year from intake_date)
group by 1, 2, 3
order by row_count desc
limit 30;