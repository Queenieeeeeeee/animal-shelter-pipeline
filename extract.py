#!/usr/bin/env python3
"""
Extract animal shelter records from municipal open data portals (Socrata).

Every run takes a FULL SNAPSHOT of each source: every row, as it stands today.
Each snapshot lands in data/raw/<source_name>/<YYYY-MM-DD>.ndjson.gz and earlier
snapshots are kept. Rows are written exactly as the API returns them -- no
renaming, no type coercion, no cleaning. That work belongs downstream in dbt,
where every transformation is visible and testable. A raw layer that has
already been "helpfully" cleaned cannot be audited against the source.

Why full snapshots rather than incremental pulls:
shelter records change after they are first published. An animal still in the
shelter at extraction time has no outcome yet; the outcome is filled in weeks
later. An incremental pull keyed on intake_date never revisits that row, so the
animal stays "in the shelter" forever and length of stay is understated --
silently. A full snapshot always carries the current state of every record,
and the series of snapshots is the history the SCD2 model is derived from.
"""

import argparse
import gzip
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import requests
import yaml

PAGE_SIZE = 50_000        # Socrata allows large pages on the JSON endpoint
MAX_PAGES = 200           # safety stop: 10M rows is far beyond any of these datasets
REQUEST_TIMEOUT = 120
MAX_RETRIES = 4

# Guards against silent partial downloads.
COUNT_TOLERANCE = 0.01    # pulled rows may differ from the API's own count by at most 1%
                          # (the portals refresh daily, so a tiny drift mid-pull is normal)
SHRINK_TOLERANCE = 0.95   # a new snapshot must hold at least 95% of the previous one's rows;
                          # shelter history only grows, so a big drop means something broke

RAW_DIR = Path("data/raw")
SOURCES_FILE = Path("sources.yml")
USER_AGENT = "animal-shelter-pipeline/1.0 (portfolio project)"

# History note: earlier versions pulled incrementally, using max(intake_date) on
# disk as a watermark. Dallas contains data-entry errors such as 2920-05-05 and
# 2030-12-31 (mistyped 2020), which parked that watermark in the year 2920 so
# every later run returned nothing -- a silent failure, guarded by a ceiling.
# Full snapshots have no watermark, so that failure mode no longer exists. The
# bad dates stay untouched in raw and are flagged by a plausibility test in the
# staging models.


def load_sources() -> list[dict]:
    if not SOURCES_FILE.exists():
        sys.exit(f"{SOURCES_FILE} not found -- run from the repository root.")
    with SOURCES_FILE.open(encoding="utf-8") as fh:
        config = yaml.safe_load(fh)
    sources = config.get("sources") or []
    if not sources:
        sys.exit("No sources defined in sources.yml.")
    return sources


def endpoint(source: dict) -> str:
    return f"https://{source['domain']}/resource/{source['dataset_id']}.json"


def get_json(url: str, params: dict) -> list[dict]:
    """GET with retries on rate limits and transient server errors."""
    headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}

    for attempt in range(MAX_RETRIES):
        resp = requests.get(url, params=params, headers=headers, timeout=REQUEST_TIMEOUT)

        if resp.status_code == 200:
            return resp.json()

        if resp.status_code == 429 or resp.status_code >= 500:
            wait = 2 ** attempt * 5
            print(f"    HTTP {resp.status_code}; retrying in {wait}s "
                  f"({attempt + 1}/{MAX_RETRIES})")
            time.sleep(wait)
            continue

        # 400 usually means a malformed query -- a bug, not something a retry will fix.
        sys.exit(f"    HTTP {resp.status_code} from {url}\n    {resp.text[:400]}")

    sys.exit(f"    Gave up on {url} after {MAX_RETRIES} attempts")


def remote_count(source: dict) -> int:
    """How many rows the portal itself says the dataset holds."""
    result = get_json(endpoint(source), {"$select": "count(*)"})
    return int(next(iter(result[0].values())))


def pull(source: dict) -> list[dict]:
    """
    Page through the whole dataset.

    Ordered by :id, Socrata's internal row id, which is unique. Paging with
    $offset needs a unique sort key: ordering by a column with ties (such as
    intake_date, where many animals share a day) lets rows shift between pages,
    so some are fetched twice and others never.
    """
    url = endpoint(source)
    rows: list[dict] = []

    for page in range(MAX_PAGES):
        batch = get_json(url, {
            "$order": ":id",
            "$limit": PAGE_SIZE,
            "$offset": page * PAGE_SIZE,
        })
        if not batch:
            break
        rows.extend(batch)
        print(f"    page {page + 1}: {len(batch):,} rows (total {len(rows):,})")
        if len(batch) < PAGE_SIZE:
            break
    else:
        sys.exit(f"    Hit MAX_PAGES ({MAX_PAGES}) without reaching the end -- "
                 f"raise the limit if the dataset really is this large.")

    return rows


def previous_snapshot(source: dict, today: str) -> tuple[Path, int] | None:
    """The most recent snapshot from an earlier day, and its row count."""
    source_dir = RAW_DIR / source["name"]
    if not source_dir.exists():
        return None

    earlier = sorted(p for p in source_dir.glob("*.ndjson.gz") if p.name[:10] < today)
    if not earlier:
        return None

    latest = earlier[-1]
    with gzip.open(latest, "rt", encoding="utf-8") as fh:
        count = sum(1 for _ in fh)
    return latest, count


def check(source: dict, rows: list[dict], expected: int,
          previous: tuple[Path, int] | None, allow_shrink: bool) -> None:
    """
    Fail loudly rather than commit a snapshot that is quietly incomplete.

    A failed check stops the run before anything is committed, so the repo
    never holds a bad snapshot.
    """
    pulled = len(rows)

    if pulled == 0:
        sys.exit("  FAILED: zero rows returned. A live shelter dataset is never empty.")

    drift = abs(pulled - expected) / expected if expected else 1.0
    if drift > COUNT_TOLERANCE:
        sys.exit(f"  FAILED: pulled {pulled:,} rows but the portal reports {expected:,} "
                 f"({drift:.1%} apart). The download is probably incomplete.")
    print(f"  count check: pulled {pulled:,}, portal reports {expected:,}  OK")

    if previous:
        prev_path, prev_count = previous
        if pulled < prev_count * SHRINK_TOLERANCE and not allow_shrink:
            sys.exit(f"  FAILED: {pulled:,} rows, down from {prev_count:,} in {prev_path.name}. "
                     f"Shelter history should only grow. If the portal really did remove "
                     f"records, re-run with --allow-shrink.")
        print(f"  shrink check: {prev_count:,} in {prev_path.name} -> {pulled:,} now  OK")


def write(source: dict, rows: list[dict], extracted_at: str) -> Path:
    """
    Write one gzipped NDJSON snapshot, named by extraction date.

    `_extracted_at` and `_source` are the only fields added. Everything else is
    the API's payload untouched, so the raw file can always be diffed against
    the portal. Written to a temporary file first and renamed at the end, so a
    crash mid-write never leaves a half-finished snapshot behind. Re-running on
    the same day replaces that day's snapshot.
    """
    source_dir = RAW_DIR / source["name"]
    source_dir.mkdir(parents=True, exist_ok=True)
    out_path = source_dir / f"{extracted_at[:10]}.ndjson.gz"
    tmp_path = source_dir / f"{extracted_at[:10]}.tmp"

    with gzip.open(tmp_path, "wt", encoding="utf-8") as fh:
        for row in rows:
            row["_extracted_at"] = extracted_at
            row["_source"] = source["name"]
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")

    tmp_path.replace(out_path)
    return out_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", help="run a single source by name")
    parser.add_argument("--allow-shrink", action="store_true",
                        help="accept a snapshot smaller than the previous one")
    args = parser.parse_args()

    sources = load_sources()
    if args.source:
        sources = [s for s in sources if s["name"] == args.source]
        if not sources:
            sys.exit(f"No source named '{args.source}' in sources.yml.")

    extracted_at = datetime.now(timezone.utc).isoformat()
    today = extracted_at[:10]
    total = 0

    for source in sources:
        print(f"\n{source['name']}  ({source['shelter']}, {source['city']}, {source['state']})")

        expected = remote_count(source)
        print(f"  portal reports {expected:,} rows; taking full snapshot")

        rows = pull(source)
        check(source, rows, expected, previous_snapshot(source, today), args.allow_shrink)

        path = write(source, rows, extracted_at)
        size_mb = path.stat().st_size / 1024 / 1024
        print(f"  wrote {len(rows):,} rows to {path} [{size_mb:,.1f} MB]")
        total += len(rows)

    print(f"\nDone. {total:,} rows across {len(sources)} source(s), snapshot {today}.")


if __name__ == "__main__":
    main()
