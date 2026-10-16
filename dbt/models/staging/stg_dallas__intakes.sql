-- Dallas intakes: current (FY2023-2026) + historical (FY2022-2023) combined.
-- One row per impound_number (one record).
-- Uses the latest snapshot of each table. Earlier snapshots feed the SCD2 model later.

{% set raw_columns = [
    'impound_number', 'animal_id', 'animal_type', 'animal_breed',
    'intake_type', 'intake_subtype', 'intake_condition', 'reason',
    'intake_date', 'intake_time',
    'outcome_type', 'outcome_subtype', 'outcome_condition',
    'outcome_date', 'outcome_time',
    'kennel_number', 'kennel_status', 'chip_status', 'animal_origin',
    'council_district', 'census_tract',
    '_snapshot_date'
] %}

with current_rows as (
    select {{ raw_columns | join(', ') }},
           'dallas_current' as source_table,
           1 as source_priority
    from {{ source('raw', 'dallas_current') }}
    qualify _snapshot_date = max(_snapshot_date) over ()
),

historical_rows as (
    select {{ raw_columns | join(', ') }},
           'dallas_historical' as source_table,
           2 as source_priority
    from {{ source('raw', 'dallas_historical') }}
    qualify _snapshot_date = max(_snapshot_date) over ()
),

unioned as (
    select * from current_rows
    union all
    select * from historical_rows
),

-- No overlap found on 2026-10-15, but keep the guard:
-- if a record ever appears in both tables, the current table wins.
deduped as (
    select *
    from unioned
    qualify row_number() over (
        partition by impound_number
        order by source_priority
    ) = 1
),

typed as (
    select
        impound_number,
        animal_id,

        lower(trim(animal_type))       as animal_type,
        lower(trim(animal_breed))      as animal_breed,

        lower(trim(intake_type))       as intake_type,
        lower(trim(intake_subtype))    as intake_subtype,
        lower(trim(intake_condition))  as intake_condition,
        lower(trim(reason))            as intake_reason,

        safe.parse_date('%Y-%m-%d', left(intake_date, 10))  as intake_date,
        safe.parse_time('%H:%M:%S', intake_time)            as intake_time,

        lower(trim(outcome_type))      as outcome_type,
        lower(trim(outcome_subtype))   as outcome_subtype,
        lower(trim(outcome_condition)) as outcome_condition,

        safe.parse_date('%Y-%m-%d', left(outcome_date, 10)) as outcome_date,
        -- 00:00:00 is the portal's placeholder for "no time recorded"
        safe.parse_time('%H:%M:%S', nullif(outcome_time, '00:00:00')) as outcome_time,
        outcome_time = '00:00:00'      as is_outcome_time_unknown,

        kennel_number,
        lower(trim(kennel_status))     as kennel_status,
        lower(trim(chip_status))       as chip_status,
        lower(trim(animal_origin))     as animal_origin,
        council_district,
        census_tract,

        source_table,
        _snapshot_date                 as snapshot_date
    from deduped
)

select
    *,
    datetime(intake_date, intake_time)   as intake_at,
    datetime(outcome_date, outcome_time) as outcome_at,

    -- What the row actually is. Dallas mixes real shelter stays with
    -- online lost/found reports and resource requests in the same dataset.
    case
        when intake_type = 'resource'                     then 'resource_request'
        when intake_subtype = 'web'
          or outcome_type in ('lost exp', 'found exp')    then 'lost_found_report'
        else 'shelter_stay'
    end as record_type,

    -- Year encoded in the impound number (K24-... = 2024). Informational only:
    -- 99.4% match intake year, but mismatches follow year-boundary patterns,
    -- so it is not used as a data quality rule.
    2000 + safe_cast(regexp_extract(impound_number, r'^[A-Z](\d{2})-') as int64)
        as impound_prefix_year,

    -- Flag, don't delete. Raw keeps the row; marts decide what to exclude.
    -- Upper bound is the snapshot date, not today, so the flag is reproducible.
    (
        intake_date is null
        or intake_date < date '2010-01-01'
        or intake_date > snapshot_date
    ) as is_intake_date_implausible,

    coalesce(outcome_date < intake_date, false) as is_outcome_before_intake

from typed