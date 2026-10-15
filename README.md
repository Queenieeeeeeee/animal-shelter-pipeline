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

## Architecture

```
Municipal open data portals (Socrata, no API key)
        │
        │  extract.py — full snapshot of every source, monthly
        ▼
GitHub: data/raw/<source>/<date>.ndjson.gz    ← system of record, every snapshot kept
        │
        │  load.py — rebuilds each table from all snapshots
        ▼
BigQuery: raw.<source>                        ← rebuildable copy for querying
        │
        │  dbt — staging → dimensions → facts → marts
        ▼
Power BI
```

All of it runs in GitHub Actions on the 1st of each month. Nothing runs on a
personal machine.

| Layer | Status |
|---|---|
| Extraction (`extract.py` + GitHub Actions) | ✅ built |
| Raw storage (`data/raw/`) | ✅ accumulating monthly snapshots |
| Warehouse load (`load.py` → BigQuery) | ✅ built |
| Transformation (dbt) | ⬜ planned |
| Dashboard (Power BI) | ⬜ planned |

**Storage and compute are separate.** GitHub holds every raw snapshot
permanently; BigQuery holds a copy that can be dropped and rebuilt from those
files at any time. This is the same split as a data lake (GCS, S3) feeding a
warehouse, with the repo playing the part of the lake.

**The raw layer stays raw.** No renaming, no type coercion, no cleaning at
extraction or load — only lineage fields are added (`_extracted_at`, `_source`,
`_snapshot_date`). Every transformation happens in dbt, where it is visible,
tested, and reversible. A raw layer that has already been helpfully cleaned can
no longer be audited against its source.

---

## Repository contents

| File | What it does |
|---|---|
| `extract.py` | Downloads a full snapshot of every source from its open data portal and saves it as a dated, gzipped NDJSON file. Checks the row count against the portal's own count before saving. |
| `load.py` | Rebuilds one BigQuery table per source from every snapshot on disk, adding a `_snapshot_date` column so snapshots can be told apart. Verifies the loaded row count. |
| `sources.yml` | The source registry: which portals and datasets to pull. Adding a shelter is a new entry here, not a code change. |
| `requirements.txt` | Python packages the scripts need. |
| `.github/workflows/refresh.yml` | The monthly schedule: extract → commit the new snapshot to the repo → load into BigQuery. Can also be run by hand from the **Actions** tab. |
| `.gitignore` | Keeps local environments, caches and credentials out of the repo. |
| `data/raw/<source>/` | One gzipped NDJSON file per monthly snapshot, exactly as the API returned it. |

---

## Data quality is part of the story, not a preamble

### Mistyped dates in Dallas

Dallas contains real data-entry errors in `intake_date`:

```
"intake_date": "2920-05-05T00:00:00.000"    # 2020, mistyped
"intake_date": "2030-12-31T00:00:00.000"    # 2020, mistyped
```

These are left untouched in raw. They are a genuine finding about the source,
and removing them at extraction would hide the reason the staging models need a
date plausibility test.

They also broke the first version of the extractor. It pulled incrementally,
using the newest `intake_date` on disk as a watermark. One row from the year 2920
parked that watermark nine centuries in the future, after which every run
returned nothing — successfully, with a green check mark. The pipeline would
have silently stopped collecting.

### Incremental pulls never see updates

Guarding the watermark fixed that, but exposed a deeper problem. Shelter records
change after they are published: an animal still in the shelter has no outcome
yet, and the outcome is filled in weeks later. An incremental pull keyed on
`intake_date` never revisits that row. The animal stays "in the shelter" in the
local copy forever, and since the animals still waiting are the ones that wait
longest, average length of stay is understated — again, silently.

The extractor now takes a **full snapshot** every month instead. That removes
the watermark (and the 2920 problem with it), keeps every record current, and
the series of snapshots becomes the history that the slowly changing dimension
is built from.

Both failures share a shape: no error, plausible-looking numbers, wrong answer.
That is the expensive kind, so the pipeline is built to fail loudly instead.

---

## Design notes

**Full snapshots, checked before they are kept.** Each run downloads every
row, then compares the count with the portal's own `count(*)` (must match within
1%) and with the previous snapshot (must not shrink by more than 5% — shelter
history only grows). A failed check stops the run before anything is committed,
so the repo never holds a quietly incomplete snapshot. `--allow-shrink` exists
for the rare case where a portal genuinely removes records.

**Stable paging.** Pages are ordered by Socrata's unique internal row id. Paging
by `intake_date` looks natural, but many animals share a date, and a sort key
with ties lets rows shift between pages — some fetched twice, others never.

**Idempotent warehouse load.** `load.py` drops and rebuilds each table from all
snapshots rather than appending the newest one. Running it twice gives the same
table, not duplicates, and a lost table is restored by running it again.

**Working within the BigQuery sandbox.** The project runs on the free sandbox,
which has no DML (no `INSERT`/`UPDATE`/`MERGE`) and expires tables 60 days after
creation. A full rebuild needs no DML and restarts the 60-day clock each month.
Tables are deliberately **not** partitioned: in the sandbox a partition also
expires 60 days after its own date, so partitioning by snapshot date would
silently delete every snapshot older than two months.

**History without MERGE.** dbt's built-in snapshots rely on `MERGE`, which the
sandbox does not allow. The slowly changing dimension is instead derived with
window functions over the stored monthly snapshots — a plain `SELECT` that dbt
rebuilds from scratch each run.

**Retries that distinguish causes.** Rate limits (429) and server errors (5xx)
back off exponentially and retry. A 400 fails immediately — it means a malformed
query, and no amount of retrying will fix that.

**Least-privilege credentials.** GitHub Actions signs in to Google Cloud as a
dedicated service account holding only *BigQuery Data Editor* and *BigQuery Job
User*. Its key lives in GitHub Secrets, never in the repo.

### Known limitations

- **Monthly granularity.** A status that changes twice within a month shows only
  its end state.
- **The first snapshot (2026-10-01)** was taken with the earlier extractor, which
  paged by `intake_date` and may contain a few duplicated or missing rows. It is
  kept as-is; duplicates are removed in staging.
- **Repo growth.** Each snapshot is about 8.5 MB compressed, roughly 100 MB a
  year — fine at this scale, but a longer-lived pipeline would move raw files to
  object storage.
- **Key-based authentication.** A downloaded service account key is the simplest
  working setup. Workload Identity Federation, which needs no stored key, is the
  stronger option and a planned improvement.

---

## Sources

All three are public Socrata datasets. **No API key, no registration, no signup.**

| Source | Shelter | Dataset | Refresh |
|---|---|---|---|
| `dallas_current` | Dallas Animal Services | [`uyte-zi7f`](https://www.dallasopendata.com/resource/uyte-zi7f.json) | daily |
| `dallas_historical` | Dallas Animal Services | [`f77p-sgrc`](https://www.dallasopendata.com/resource/f77p-sgrc.json) | daily |
| `sonoma` | Sonoma County Animal Services | [`924a-vesw`](https://data.sonomacounty.ca.gov/resource/924a-vesw.json) | daily |

---

## Running it

The pipeline is designed to run in GitHub Actions: **Actions → Refresh shelter
data → Run workflow**. Two options are available on a manual run:

- `skip_extract` — reload BigQuery from the snapshots already in the repo, without downloading
- `allow_shrink` — accept a snapshot smaller than the previous one

To run locally:

```bash
pip install -r requirements.txt

python extract.py                      # full snapshot of every source
python extract.py --source sonoma      # one source only

export GCP_PROJECT=<your-project-id>   # plus Google Cloud credentials
python load.py                         # rebuild every BigQuery table
```

Monthly rather than daily: these are intake and outcome records, so a day's
delay changes nothing, and a monthly cadence keeps the commit history readable.

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

## Data sources and attribution

Data from the [City of Dallas Open Data Portal](https://www.dallasopendata.com/)
and [County of Sonoma Open Data](https://data.sonomacounty.ca.gov/), both
published under their respective open data terms. This is a personal portfolio
project, not affiliated with either jurisdiction.
