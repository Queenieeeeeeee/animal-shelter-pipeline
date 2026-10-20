-- =============================================================================
-- Shared: outcome type mapping across Dallas and Sonoma
-- Run: 2026-10-19
-- Informs: seeds/outcome_type_mapping.csv
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Q1. For Dallas outcome types with unclear meaning, what intake type do they
--     come with, and how long do the animals stay?
--
-- Only shelter_stay rows: lost/found reports and resource requests are already
-- separated by record_type in staging.
--
-- Result:
--   closed     4,351  all resource_request; already excluded by record_type
--   treatment  5,258  intake_type also 'treatment', avg 0.3 days (clinic visit)
--   wildlife   1,439  intake_type also 'wildlife', avg 0.3 days (same-day handoff)
   --   disposal     999  avg 5-33 days by intake type (see Q5a: arrived dead)
--   foster    28,010  4,778 rows have intake_type 'foster': returns from
--                     foster are logged as a new impound
--   missing      535  474 have intake_type 'foster' (lost while in foster)
--   other        698  avg_days is null: no outcome_date
-- Decision:
--   treatment, wildlife: not shelter stays. Classify in record_type (to do).
--   missing: map to 'missing' (see Q6).
--   foster: not a final outcome. Stay definition depends on Q2.
--   disposal, other: open, need a closer look.
-- -----------------------------------------------------------------------------
select
    record_type,
    outcome_type,
    intake_type,
    count(*) as row_count,
    round(avg(date_diff(outcome_date, intake_date, day)), 1) as avg_days
from {{ ref('stg_dallas__intakes') }}
where outcome_type in ('foster', 'treatment', 'closed', 'wildlife',
                       'disposal', 'missing', 'other')
group by 1, 2, 3
order by 2, 4 desc;
-- -----------------------------------------------------------------------------
-- Q2. After a foster outcome, what happens to the animal next?
--
-- If most foster outcomes are followed by an intake_type 'foster' row,
-- one real stay is split across several impound records.
--
-- Result (28,010 foster outcomes, by the animal's next intake type):
--   foster           22,929  82%  avg 45.6 days later (return from foster)
--   treatment         2,698  10%  avg 25.7 days later (vet visit while fostered)
--   none              2,333   8%  not seen again yet
--   stray and others     50  <1%  90-300 days later (genuine new stays)
-- Decision: in Dallas, foster is a temporary exit, not an outcome. One real
--   stay can span several impound records. Stay definition is decided after
--   checking how Sonoma handles foster (Q3).
-- -----------------------------------------------------------------------------
with ordered as (
    select
        outcome_type,
        outcome_date,
        lead(intake_type) over w as next_intake_type,
        lead(intake_date) over w as next_intake_date
    from {{ ref('stg_dallas__intakes') }}
    where record_type = 'shelter_stay'
    window w as (partition by animal_id order by intake_date, impound_number)
)
select
    next_intake_type,
    count(*) as row_count,
    round(avg(date_diff(next_intake_date, outcome_date, day)), 1) as avg_days_until_next
from ordered
where outcome_type = 'foster'
group by 1
order by 2 desc;

-- -----------------------------------------------------------------------------
-- Q3. Sonoma has no 'foster' outcome. Where does foster appear, if anywhere?
--
-- Searches every text column that could carry it.
--
-- Result:
--   Foster is recorded in kennel_number ('FOSTER'), not as an outcome.
--   The impound stays open while the animal is in foster.
--   kennel_number = 'foster': 332 rows (adoption 167, transfer 93, open 39,
--     died 22, euthanize 6, return to owner 4, disposal 1)
--   outcome_subtype = 'in foster': 53 rows, all died
--   Calculated days = official days in every group (e.g. adoption 124.2 vs 124.2):
--     official days_in_shelter includes time in foster.
--   Open stays have official days = 0, not null.
--   kennel_number holds the last location only, so animals that returned from
--     foster to a kennel are not visible. 332 undercounts fostering.
-- Decision:
--   One stay = first intake to final outcome, including time in foster.
--   Sonoma: one impound record is already one stay.
--   Dallas: chain foster -> return-from-foster records into one stay
--     (fact table step). In the seed, 'foster' is marked as not final.
--   Validation must exclude open stays (official days = 0).
-- -----------------------------------------------------------------------------
with sonoma as (
    select * from {{ ref('stg_sonoma__intakes') }}
),

hits as (
    select 'intake_type' as column_name, intake_type as value, outcome_type,
           intake_date, outcome_date, official_days_in_shelter
    from sonoma where intake_type like '%foster%'
    union all
    select 'intake_subtype', intake_subtype, outcome_type,
           intake_date, outcome_date, official_days_in_shelter
    from sonoma where intake_subtype like '%foster%'
    union all
    select 'outcome_subtype', outcome_subtype, outcome_type,
           intake_date, outcome_date, official_days_in_shelter
    from sonoma where outcome_subtype like '%foster%'
    union all
    select 'kennel_number', lower(kennel_number), outcome_type,
           intake_date, outcome_date, official_days_in_shelter
    from sonoma where lower(kennel_number) like '%foster%'
)

select
    column_name,
    value,
    outcome_type,
    count(*) as row_count,
    round(avg(date_diff(outcome_date, intake_date, day)), 1) as avg_days_calculated,
    round(avg(official_days_in_shelter), 1)                  as avg_days_official
from hits
group by 1, 2, 3
order by 1, 4 desc;

-- -----------------------------------------------------------------------------
-- Q4. What do Dallas 'disposal' and 'other' actually mean?
--
-- disposal: animals stay 5-33 days, so not dead on arrival.
-- other: avg_days was null, so outcome_date is missing.
--
-- Result:
--   disposal (999): outcome_condition 'deceased' in 981 rows.
--     subtype disposal 838 (avg 14.2 days), rabiestest 149 (avg 1.7),
--     rto 8 (body returned to owner), other 4.
--     'disposal' is handling of a body, separate from the 'died' outcome.
--   other (573): subtype 'other', condition null, no outcome_date in every row.
-- Decision: both open until Q5:
--   disposal: is the animal dead on arrival? If so, the days are body storage
--     time and the record is not a shelter stay.
--   other: recent open records, or old records never completed?
-- -----------------------------------------------------------------------------
select
    outcome_type,
    outcome_subtype,
    outcome_condition,
    count(*)                       as row_count,
    countif(outcome_date is null)  as no_outcome_date,
    round(avg(date_diff(outcome_date, intake_date, day)), 1) as avg_days
from {{ ref('stg_dallas__intakes') }}
where record_type = 'shelter_stay'
  and outcome_type in ('disposal', 'other')
group by 1, 2, 3
order by 1, 4 desc;

-- -----------------------------------------------------------------------------
-- Q5a. Disposal: did the animal arrive dead, or die in care?
-- -----------------------------------------------------------------------------
select
    intake_type,
    intake_condition,
    count(*) as row_count,
    round(avg(date_diff(outcome_date, intake_date, day)), 1) as avg_days
from {{ ref('stg_dallas__intakes') }}
where record_type = 'shelter_stay'
  and outcome_type = 'disposal'
group by 1, 2
order by 3 desc;

-- -----------------------------------------------------------------------------
-- Q5b. 'other' with no outcome_date: recent or old?
--
-- Result and decision below cover Q5a and Q5b.
--
-- Result:
--   Q5a disposal: 996 of 999 arrived deceased (intake_condition 'deceased').
--     Days are body storage time. Longest for confiscated (23.4) and
--     keepsafe (32.8), likely held for legal or ownership reasons.
--     3 rows arrived alive (critical 2, app wnl 1).
--   Q5b other: 572 of 573 have a 2026 intake date, 1 from 2024.
-- Decision:
--   disposal: not a shelter stay. Exclude from length of stay, including
--     the 3 live-arrival rows (too few to model separately).
--   other: treat as open records, the same as Sonoma's null outcomes.
--     Length of stay stays null until an outcome date appears.
-- -----------------------------------------------------------------------------
select
    extract(year from intake_date) as intake_year,
    count(*) as row_count
from {{ ref('stg_dallas__intakes') }}
where record_type = 'shelter_stay'
  and outcome_type = 'other'
group by 1
order by 1;

-- -----------------------------------------------------------------------------
-- Q6. What do Sonoma's unclear outcome types mean?
--
-- rtos, shelter, vet, transport, escaped/stolen: meaning unknown.
-- disposal: check it matches Dallas (arrived dead, not a stay).
--
-- Result (latest snapshot):
--   disposal: subtype doa (dead on arrival) ~250, fra (rabies test) ~95.
--     Same meaning as Dallas disposal; fra = Dallas rabiestest.
--   rtos (83): subtypes phone / over the counter, prefixed s or e
--     (prefix meaning unknown). Owner reclaim.
--   vet (55): all 'vet return to owner'.
--   transport (1): 'lab fra', body sent for rabies test.
--   escaped/stolen (19): en route, in kennel, unk missng. Lost from custody.
--   shelter (72): mostly 'hold expir'. Likely the legal hold ended and
--     ownership passed to the shelter, i.e. a status change, not an exit.
-- Decision:
--   disposal, transport: disposal group, not a shelter stay (same as Dallas).
--   rtos, vet: return_to_owner.
--   escaped/stolen: missing, shared with Dallas 'missing'
--     (Dallas Q1 decision changed from 'other' to 'missing').
--   shelter: other. Too few rows (0.2%) to investigate further.
-- -----------------------------------------------------------------------------
select
    outcome_type,
    outcome_subtype,
    intake_type,
    intake_condition,
    count(*) as row_count,
    round(avg(date_diff(outcome_date, intake_date, day)), 1) as avg_days_calculated,
    round(avg(official_days_in_shelter), 1)                  as avg_days_official
from {{ ref('stg_sonoma__intakes') }}
where outcome_type in ('rtos', 'shelter', 'vet', 'transport',
                       'escaped/stolen', 'disposal')
group by 1, 2, 3, 4
order by 1, 5 desc;