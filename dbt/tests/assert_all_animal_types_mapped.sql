-- Fails if staging contains an animal_type that the mapping seed does not cover.
-- Without this, a new value would join to null and silently drop out of
-- every dog / cat / other count downstream.

with staged as (
    select distinct 'dallas' as source, animal_type
    from {{ ref('stg_dallas__intakes') }}
    union distinct
    select distinct 'sonoma' as source, animal_type
    from {{ ref('stg_sonoma__intakes') }}
)

select
    s.source,
    s.animal_type
from staged as s
left join {{ ref('animal_type_mapping') }} as m
    on  s.source      = m.source
    and s.animal_type = m.raw_animal_type
where m.raw_animal_type is null