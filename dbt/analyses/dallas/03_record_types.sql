-- =============================================================================
-- Dallas: not every row is a shelter stay
-- Run: 2026-10-16
-- Informed: record_type in stg_dallas__intakes
--   shelter_stay 142,756 / lost_found_report 12,930 / resource_request 4,367
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Q1. Which outcome types have no outcome time?
--
-- Result:
--   lost exp    9,262 / 9,262   100%
--   found exp   3,559 / 3,559   100%
--   closed      1,050 / 4,351    24%
--   every other type             <= 11%
-- Decision: 'lost exp' / 'found exp' look like expired lost/found reports,
--           not animals that were housed. Investigate before computing
--           length of stay.
-- -----------------------------------------------------------------------------
select outcome_type,
       countif(is_outcome_time_unknown) as time_unknown,
       count(*) as total,
       round(countif(is_outcome_time_unknown) / count(*) * 100, 1) as pct
from {{ ref('stg_dallas__intakes') }}
where outcome_date is not null
group by 1
order by time_unknown desc;


-- -----------------------------------------------------------------------------
-- Q2. What intake types do these records come in as?
--
-- Result:
--   stray    -> lost exp 9,261 / found exp 3,559
--   resource -> closed 4,351   (every 'closed' row)
--   foster   -> lost exp 1     (one-off)
-- Decision: intake_type = 'resource' is a resource request, not a stay.
--           Lost/found reports enter as 'stray', so intake_type alone
--           cannot separate them -> check intake_subtype (Q3).
-- -----------------------------------------------------------------------------
select intake_type, outcome_type, count(*) as row_count
from {{ ref('stg_dallas__intakes') }}
where outcome_type in ('lost exp', 'found exp', 'closed')
   or outcome_date is null
group by 1, 2
order by 1, 3 desc;


-- -----------------------------------------------------------------------------
-- Q3. Can intake_subtype identify reports at intake time?
--
-- Result:
--   web          reports 12,820   real_stays 109
--   at large     reports      0   real_stays 55,121
--   confined     reports      0   real_stays 10,234
--   (all other subtypes: 0 reports)
-- Decision: 'web' (online report) identifies every expired report.
--           Check the 109 before adopting (Q4).
-- -----------------------------------------------------------------------------
select intake_subtype,
       countif(outcome_type in ('lost exp', 'found exp'))     as reports,
       countif(outcome_type not in ('lost exp', 'found exp')) as real_stays
from {{ ref('stg_dallas__intakes') }}
where intake_type = 'stray'
group by 1
order by reports desc;


-- -----------------------------------------------------------------------------
-- Q4. Are the 109 'web' rows real stays, or reports not yet expired?
--
-- Result: all 109 have outcome_type 'other' and no outcome date (still open).
-- Decision: adopted. intake_subtype = 'web' -> lost_found_report.
--           Also kept outcome_type in ('lost exp','found exp') in the rule
--           to catch the single foster -> lost exp row.
-- -----------------------------------------------------------------------------
select outcome_type,
       outcome_date is null as still_open,
       count(*) as row_count
from {{ ref('stg_dallas__intakes') }}
where intake_type = 'stray' and intake_subtype = 'web'
  and outcome_type not in ('lost exp', 'found exp')
group by 1, 2
order by row_count desc;


-- -----------------------------------------------------------------------------
-- Check after adding record_type
--
-- Result: shelter_stay 142,756 / lost_found_report 12,930 / resource_request 4,367
--         Sum = 160,053. Matches expectations exactly.
-- -----------------------------------------------------------------------------
select record_type, count(*) as row_count
from {{ ref('stg_dallas__intakes') }}
group by 1
order by 2 desc;