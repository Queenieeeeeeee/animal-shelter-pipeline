# Animal Shelter Throughput Analytics

A multi-source data pipeline over municipal animal shelter open data, built to
answer one question:

> **What makes an animal wait longer before leaving a shelter — and why does the
> answer differ between cities?**

Length of stay is a throughput metric. So is order cycle time in a factory. The
modelling here is deliberately the same shape as operational reporting work:
measure how long a unit sits in the system, find what predicts the slow ones,
and make the difference between sites comparable.

---

## Why more than one shelter

A single shelter's data answers "how are we doing". Two shelters answer "compared
to whom" — which is the more useful question, and the harder engineering problem,
because no two municipal portals publish the same shape of data.

Dallas and Sonoma County both publish intake and outcome records. They agree on
almost nothing else:

| | Dallas | Sonoma County |
|---|---|---|
| Animal type column | `animal_type` | `type` |
| Breed column | `animal_breed` | `breed` |
| Value casing | `DOG`, `STRAY`, `AMER SH` | `Dog`, `Stray`, `Domestic Shorthair` |
| Date and time | `intake_date` + `intake_time` (separate) | `intake_date` only |
| Length of stay | must be derived | published as `days_in_shelter` |
| Location | `kennel_number`, `impound_number` | `zip_code`, lat/long `location` |
| Breed vocabulary | abbreviated (`CHIHUAHUA LH`) | spelled out (`Chihuahua, Long Haired`) |

Reconciling those into one model — one grain, one vocabulary, one definition of
"adopted" — is the substance of this project. Sonoma publishing
`days_in_shelter` while Dallas does not is a gift: it gives an independent check
on the derived metric, so the derivation can be validated rather than trusted.

---

## Data quality is part of the story, not a preamble

Dallas contains real data-entry errors in `intake_date`:

```
"intake_date": "2920-05-05T00:00:00.000"    # 2020, mistyped
"intake_date": "2030-12-31T00:00:00.000"    # 2020, mistyped
```

These are left untouched in the raw layer. They are a genuine finding about the
source, and removing them at extraction would hide the reason the staging models
need a date plausibility test.

They do, however, break naive incremental logic: take the maximum `intake_date`
as a watermark and the cursor parks itself in the year 2920, after which every
subsequent run returns nothing and the pipeline silently stops collecting. The
extractor caps the watermark below a sanity ceiling for exactly this reason
(`WATERMARK_CEILING` in `extract.py`).

That failure mode is silent, which makes it the expensive kind.

---

## Architecture

```
Municipal open data portals (Socrata, no API key)
        │
        │  extract.py  — incremental by watermark, config-driven
        ▼
data/raw/<source>/<date>.ndjson.gz      ← untransformed, as the API returned it
        │
        ▼
BigQuery                                 ← planned
        │
        │  dbt  — staging → dimensions → facts → marts
        ▼
Power BI                                 ← planned
```

| Layer | Status |
|---|---|
| Extraction (`extract.py` + GitHub Actions) | ✅ built |
| Raw storage (`data/raw/`) | ✅ accumulating |
| Warehouse load (BigQuery) | ⬜ planned |
| Transformation (dbt) | ⬜ planned |
| Dashboard (Power BI) | ⬜ planned |

**The raw layer stays raw.** No renaming, no type coercion, no cleaning at
extraction — only two lineage fields (`_extracted_at`, `_source`) are added.
Every transformation happens in dbt where it is visible, tested, and reversible.
A raw layer that has already been helpfully cleaned can no longer be audited
against its source.

---

## Sources

All three are public Socrata datasets. **No API key, no registration, no signup.**
Clone the repo and it runs.

| Source | Shelter | Dataset | Refresh |
|---|---|---|---|
| `dallas_current` | Dallas Animal Services | [`uyte-zi7f`](https://www.dallasopendata.com/resource/uyte-zi7f.json) | daily |
| `dallas_historical` | Dallas Animal Services | [`f77p-sgrc`](https://www.dallasopendata.com/resource/f77p-sgrc.json) | daily |
| `sonoma` | Sonoma County Animal Services | [`924a-vesw`](https://data.sonomacounty.ca.gov/resource/924a-vesw.json) | daily |

Adding a shelter means adding an entry to `sources.yml`. No code change.

---

## Running it

```bash
pip install -r requirements.txt

python extract.py                      # incremental — only rows newer than what is held
python extract.py --full-refresh       # re-pull everything from the beginning
python extract.py --source sonoma      # one source only
```

The first run is a full pull and takes a few minutes. After that each run moves
only new records.

### Scheduled runs

`.github/workflows/refresh.yml` runs on the 1st of each month and commits any new
records back to the repo. It can also be triggered by hand from the **Actions**
tab, with an optional full refresh.

Monthly rather than daily: these are historical intake and outcome records, so a
day's delay changes nothing, and a monthly cadence keeps the commit history
readable.

---

## Planned metrics

**Length of Stay** — days from intake to outcome, by shelter, animal type,
breed group, intake condition and month. The core outcome variable. Validated
against Sonoma's published `days_in_shelter`.

**Outcome Mix** — the share of intakes ending in adoption, return to owner,
transfer, or euthanasia, and how that mix shifts with length of stay. A shelter
with a fast average that is fast for the wrong reason should not read as a
high performer, so the two metrics have to be read together.

**Capacity and Turnover** — animals on hand over time per shelter, derived by
walking intakes and outcomes forward day by day, and how quickly that population
cycles. High intake with slow turnover is a capacity problem, and its shape is
visible in the daily counts.

---

## Design notes

**Incremental by watermark, read from disk.** The cursor is derived from the
data actually on disk rather than a separate state file. A state file can drift
out of step with reality after a failed run or a manual delete; the files cannot.

**Retries that distinguish causes.** Rate limits (429) and transient server
errors (5xx) back off exponentially and retry. A 400 fails immediately and
loudly — it means a column name in `sources.yml` is wrong, and no amount of
retrying will fix a malformed query.

**Config-driven sources.** `sources.yml` is the registry. The extractor has no
shelter-specific code paths, so a new city is a data change, not a code change.

---

## Data sources and attribution

Data from the [City of Dallas Open Data Portal](https://www.dallasopendata.com/)
and [County of Sonoma Open Data](https://data.sonomacounty.ca.gov/), both
published under their respective open data terms. This is a personal portfolio
project, not affiliated with either jurisdiction.
