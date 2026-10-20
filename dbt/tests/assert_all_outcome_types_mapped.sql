-- Fails if any outcome_type in staging has no row in the mapping seed.
-- Without this, a new outcome value would join to null and silently
-- drop out of the dashboard.

with staging_values as (

    select distinct 'dallas' as source, outcome_type
    from {{ ref('stg_dallas__intakes') }}
    where outcome_type is not null

    union distinct

    select distinct 'sonoma' as source, outcome_type
    from {{ ref('stg_sonoma__intakes') }}
    where outcome_type is not null

)

select s.source, s.outcome_type
from staging_values as s
left join {{ ref('outcome_type_mapping') }} as m
    on  m.source = s.source
    and m.raw_outcome_type = s.outcome_type
where m.raw_outcome_type is null