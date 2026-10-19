-- One row per impound (latest snapshot only).
-- Earlier snapshots feed the SCD2 model later, read directly from raw.
-- Renames to the shared vocabulary, casts types, lowercases codes.
-- Nothing is filtered out: implausible dates are flagged, not removed.

with source as (

    select * from {{ source('raw', 'sonoma') }}
    qualify _snapshot_date = max(_snapshot_date) over ()

),

renamed as (

    select
        -- keys
        impound_number                                   as intake_id,
        id                                               as animal_id,
        _snapshot_date                                   as snapshot_date,

        -- animal
        lower(type)                                      as animal_type,
        lower(breed)                                     as breed,
        lower(color)                                     as color,
        lower(sex)                                       as sex,
        lower(size)                                      as size,
        name                                             as animal_name,
        date(safe_cast(date_of_birth as datetime))       as date_of_birth,

        -- intake
        date(safe_cast(intake_date as datetime))         as intake_date,
        lower(intake_type)                               as intake_type,
        lower(intake_subtype)                            as intake_subtype,
        lower(intake_condition)                          as intake_condition,
        lower(intake_jurisdiction)                       as intake_jurisdiction,
        safe_cast(intake_total as int64)                 as intake_total,
        kennel_number,

        -- outcome
        date(safe_cast(outcome_date as datetime))        as outcome_date,
        lower(outcome_type)                              as outcome_type,
        lower(outcome_subtype)                           as outcome_subtype,
        lower(outcome_condition)                         as outcome_condition,
        lower(outcome_jurisdiction)                      as outcome_jurisdiction,

        -- location
        zip_code,
        safe_cast(json_value(location, '$.latitude')  as float64) as latitude,
        safe_cast(json_value(location, '$.longitude') as float64) as longitude,

        -- Sonoma's own length of stay, kept to validate our derived one
        safe_cast(days_in_shelter as int64)              as official_days_in_shelter,

        -- lineage
        _extracted_at                                    as extracted_at

    from source

)

select
    *,
    concat(intake_id, '|', cast(snapshot_date as string)) as snapshot_record_id,
    intake_date not between date '2000-01-01' and snapshot_date
        as is_intake_date_implausible

from renamed