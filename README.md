# Shelter Throughput Pipeline

A daily-snapshot data pipeline over the Petfinder API, built to answer one
question: **what makes an animal wait longer before being adopted?**

Breed, age, size, special needs, listing quality — the API exposes all of it,
but only as a snapshot of *right now*. It has no history. So this pipeline
takes a snapshot every day and lets the history accumulate, which is what
makes time-to-adoption measurable at all.

---

## Why daily snapshots

The Petfinder API answers "who is adoptable today". It cannot answer "how long
did this animal wait". The second question is the interesting one, and the only
way to get it is to record the first answer every day and diff the results:

- An animal that appears on 2026-10-01 and is gone by 2026-10-14 waited ~13 days.
- An animal whose `status` flips from `adoptable` to `adopted` gives an exact date.
- An animal that moves between organizations is a transfer, not an adoption.

None of this is recoverable retroactively. **The history starts the day the
pipeline starts running** — which is why step one is getting the collector live,
before any modelling work.

---

## Current state

| Layer | Status |
|---|---|
| Ingestion (`pull.py` + GitHub Actions) | ✅ running daily |
| Raw storage (`data/raw/*.jsonl.gz`) | ✅ accumulating |
| Warehouse load (BigQuery) | ⬜ planned |
| Transformation (dbt) | ⬜ planned |
| Dashboard (Power BI) | ⬜ planned |

---

## Setup

### 1. Get Petfinder API credentials

Sign up at [petfinder.com/developers](https://www.petfinder.com/developers/) and
create an application. You get a **key** and a **secret**. Free.

### 2. Add them to GitHub

In the repo: **Settings → Secrets and variables → Actions → New repository secret**

| Name | Value |
|---|---|
| `PETFINDER_KEY` | your API key |
| `PETFINDER_SECRET` | your API secret |

These never appear in the code or the logs.

### 3. Turn the workflow on

Go to the **Actions** tab and enable workflows if prompted. Then run
**Daily Petfinder snapshot → Run workflow** once by hand to confirm it works —
don't wait until tomorrow to find out the credentials were wrong.

A successful run writes `data/raw/YYYY-MM-DD.jsonl.gz` and commits it.

### 4. (Optional) Run it locally

```bash
pip install -r requirements.txt
cp .env.example .env          # then fill in your key and secret
export $(grep -v '^#' .env | xargs)
python pull.py
```

---

## What gets collected

Scope is set at the top of `pull.py`: dogs and cats within 500 miles of
Phoenix, AZ (the API's maximum radius). Each animal's `state` is recorded, so
the scope can be narrowed later without re-collecting.

One line per animal per day, gzipped JSONL. Roughly 1 MB/day at this scope.

**On `description`:** breed, size, age and temperament all arrive as their own
structured fields, so the shelter's free-text write-up isn't needed to identify
the animal. What the text uniquely carries is backstory, behavioural notes and
medical detail — so the first 500 characters are kept, along with the full
length and a truncation flag. Storing the text whole would roughly triple the
daily files for diminishing returns.

### Fields

| Group | Fields |
|---|---|
| Snapshot | `snapshot_date`, `pulled_at` |
| Identity | `animal_id`, `organization_id`, `url` |
| Characteristics | `type`, `species`, `breed_primary`, `breed_secondary`, `breed_mixed`, `breed_unknown`, `color_primary`, `age`, `gender`, `size`, `coat` |
| Care attributes | `spayed_neutered`, `house_trained`, `declawed`, `special_needs`, `shots_current`, `good_with_children`, `good_with_dogs`, `good_with_cats`, `tags` |
| Listing quality | `photo_count`, `video_count`, `has_description`, `description_length`, `description_truncated`, `description_excerpt` |
| Status | `status`, `published_at`, `status_changed_at` |
| Location | `city`, `state`, `postcode`, `distance_miles` |


---

## Planned metrics

Three, all of which are throughput measures rather than counts:

**Length of Stay** — days between an animal first appearing in the data and
disappearing (or flipping to `adopted`). The core outcome variable.

**Shelter Capacity & Turnover** — active listings per organization over time,
and how fast that population cycles. High intake with low turnover is a
capacity problem; the shape of it is visible in the daily counts.

**Listing Quality vs. Outcome** — whether photo count, description presence,
and completeness of care attributes correlate with a shorter stay. The one
finding here that would be genuinely actionable for a shelter.

---

## Design notes

**Deduplication.** Listings shift position between API calls, so the same
animal can appear on two adjacent pages of one pull. The collector tracks IDs
within a run and writes each animal once per day.

**Retries.** Rate limits (429) and transient server errors (5xx) back off
exponentially and retry. A 400 or 403 fails loudly instead — those mean the
request itself is wrong and retrying won't fix it.

**Empty runs fail.** If a run writes zero records, it exits non-zero so the
scheduled job goes red. A silently empty snapshot is worse than a visible
failure, because it leaves a hole in the history that can't be backfilled.

**Off-the-hour schedule.** The cron runs at 11:17 UTC rather than on the hour,
since GitHub queues scheduled jobs and the ones set to :00 are the most likely
to be delayed or skipped.

---

## Data source

Data from the [Petfinder API](https://www.petfinder.com/developers/). This is a
personal portfolio project and is not affiliated with or endorsed by Petfinder.
