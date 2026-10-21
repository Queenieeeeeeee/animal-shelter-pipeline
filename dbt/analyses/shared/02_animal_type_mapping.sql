-- =====================================================================
-- 02_animal_type_mapping.sql
-- Purpose: evidence for seeds/animal_type_mapping.csv
-- Each query: Question / Result / Decision
-- =====================================================================


-- ---------------------------------------------------------------------
-- Q1. What animal_type values exist in each city, and how many rows?
-- Result: Dallas has 5 values: dog 61.9%, cat 29.2%, bird 6.6%,
--         wildlife 2.2%, livestock 0.1%. Sonoma has 3: dog 56.7%,
--         cat 34.8%, other 8.5%. No nulls on either side.
--         Sonoma has no bird / wildlife / livestock: they are all folded
--         into "other", so the two vocabularies only share dog and cat.
-- Decision: Unified vocabulary is dog / cat / other, the only level both
--           cities share reliably. All Dallas bird / wildlife / livestock
--           map to other. See Q3 for why finer groups are not kept here.
-- ---------------------------------------------------------------------
with combined as (
    select 'dallas' as source, animal_type from {{ ref('stg_dallas__intakes') }}
    union all
    select 'sonoma' as source, animal_type from {{ ref('stg_sonoma__intakes') }}
)
select
    source,
    coalesce(animal_type, '(null)') as animal_type,
    count(*) as n,
    round(100 * count(*) / sum(count(*)) over (partition by source), 2) as pct
from combined
group by 1, 2
order by source, n desc;


-- ---------------------------------------------------------------------
-- Q2. Dallas: are the minority types real shelter stays,
--     or mostly lost/found reports and resource requests?
-- Result: Real stays. bird 99.5%, wildlife 98.9%, livestock 84.6% are
--         shelter_stay. Lost/found and resource requests are almost
--         entirely dog and cat.
-- Decision: Minority types cannot be dropped as noise; they are
--           genuine records and need a mapping.
-- ---------------------------------------------------------------------
select
    coalesce(animal_type, '(null)') as animal_type,
    count(*) as n_total,
    countif(record_type = 'shelter_stay')      as n_shelter_stay,
    countif(record_type = 'lost_found_report') as n_lost_found,
    countif(record_type = 'resource_request')  as n_resource
from {{ ref('stg_dallas__intakes') }}
group by 1
order by n_total desc;


-- ---------------------------------------------------------------------
-- Q3. For everything that is not dog or cat: what breeds sit under
--     each type? (Tells us what "other" / "livestock" actually contain.)
-- Result: Dallas "bird" is 92% chicken + gamefowl, not pet birds.
--         Dallas "wildlife" includes pets (rabbit sh/lh 312, guinea pig 231,
--         rat 92), so the Dallas type is unreliable for small animals.
--         Sonoma "other" mixes poultry, bats, rabbits, livestock, horses
--         and parakeets: the union of Dallas bird + wildlife + livestock.
-- Decision: Keep dog / cat / other only. Finer groups (rabbit, poultry,
--           wildlife, livestock) need breed, so they belong in the breed
--           mapping later, not here. Raw animal_type stays in staging.
-- ---------------------------------------------------------------------
with combined as (
    select 'dallas' as source, animal_type, animal_breed as breed
    from {{ ref('stg_dallas__intakes') }}
    union all
    select 'sonoma' as source, animal_type, breed
    from {{ ref('stg_sonoma__intakes') }}
),
counted as (
    select source, animal_type, breed, count(*) as n
    from combined
    where animal_type not in ('dog', 'cat')
    group by 1, 2, 3
)
select *
from counted
qualify row_number() over (partition by source, animal_type order by n desc) <= 10
order by source, animal_type, n desc;