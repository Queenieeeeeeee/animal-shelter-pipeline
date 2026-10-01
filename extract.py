#!/usr/bin/env python3
"""
Extract animal shelter records from municipal open data portals (Socrata).

Each source lands in data/raw/<source_name>/ as dated, gzipped NDJSON. Rows are
written exactly as the API returns them -- no renaming, no type coercion, no
cleaning. Those belong downstream in dbt, where every transformation is visible
and testable. A raw layer that has already been "helpfully" cleaned cannot be
audited against the source.

Incremental by default: each run asks the API only for rows newer than the
newest row already on disk. --full-refresh overrides that and re-pulls
everything, which is what you want after changing a source definition.
"""

import argparse
import gzip
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import requests
import yaml

PAGE_SIZE = 50_000        # Socrata allows large pages on the JSON endpoint
MAX_PAGES = 200           # safety stop: 10M rows is far beyond any of these datasets
REQUEST_TIMEOUT = 120
MAX_RETRIES = 4

RAW_DIR = Path("data/raw")
SOURCES_FILE = Path("sources.yml")
USER_AGENT = "animal-shelter-pipeline/1.0 (portfolio project)"

# Dallas contains data-entry errors in intake_date -- values like 2920-05-05 and
# 2030-12-31, clearly mistyped from 2020. Left in the raw layer on purpose: they
# are a genuine data quality finding and the reason the staging models need a
# plausibility test. But they must not be allowed to set the incremental
# watermark, or one typo parks the cursor in the year 2920 and every later run
# returns nothing.
WATERMARK_CEILING = "2027-01-01"


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
            import time
            time.sleep(wait)
            continue

        # 400 usually means a bad column name in $where or $order -- a bug in
        # sources.yml, not something a retry will fix.
        sys.exit(f"    HTTP {resp.status_code} from {url}\n    {resp.text[:400]}")

    sys.exit(f"    Gave up on {url} after {MAX_RETRIES} attempts")


def local_watermark(source: dict) -> str | None:
    """
    Highest watermark value already held locally.

    Read from the files rather than tracked in a state file: the data on disk is
    the only thing that is definitely true. A state file can drift out of step
    with it after a failed run or a manual delete.
    """
    column = source["watermark"]
    source_dir = RAW_DIR / source["name"]
    if not source_dir.exists():
        return None

    highest = None
    for path in sorted(source_dir.glob("*.ndjson.gz")):
        with gzip.open(path, "rt", encoding="utf-8") as fh:
            for line in fh:
                value = json.loads(line).get(column)
                if not value or value >= WATERMARK_CEILING:
                    continue
                if highest is None or value > highest:
                    highest = value
    return highest


def pull(source: dict, since: str | None) -> list[dict]:
    """Page through one dataset, oldest first, from `since` onward."""
    url = endpoint(source)
    column = source["watermark"]

    clauses = [f"{column} IS NOT NULL"]
    if since:
        clauses.append(f"{column} > '{since}'")
    where = " AND ".join(clauses)

    rows: list[dict] = []
    for page in range(MAX_PAGES):
        batch = get_json(url, {
            "$where": where,
            "$order": f"{column} ASC",
            "$limit": PAGE_SIZE,
            "$offset": page * PAGE_SIZE,
        })
        if not batch:
            break
        rows.extend(batch)
        print(f"    page {page + 1}: {len(batch):,} rows (total {len(rows):,})")
        if len(batch) < PAGE_SIZE:
            break

    return rows


def write(source: dict, rows: list[dict], extracted_at: str) -> Path:
    """
    Write one gzipped NDJSON file, stamped with the extraction time.

    `_extracted_at` and `_source` are the only fields added. Everything else is
    the API's payload untouched, so the raw file can always be diffed against
    the portal.
    """
    source_dir = RAW_DIR / source["name"]
    source_dir.mkdir(parents=True, exist_ok=True)
    out_path = source_dir / f"{extracted_at[:10]}.ndjson.gz"

    with gzip.open(out_path, "wt", encoding="utf-8") as fh:
        for row in rows:
            row["_extracted_at"] = extracted_at
            row["_source"] = source["name"]
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")

    return out_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--full-refresh", action="store_true",
                        help="ignore local data and re-pull each source from the beginning")
    parser.add_argument("--source", help="run a single source by name")
    args = parser.parse_args()

    sources = load_sources()
    if args.source:
        sources = [s for s in sources if s["name"] == args.source]
        if not sources:
            sys.exit(f"No source named '{args.source}' in sources.yml.")

    extracted_at = datetime.now(timezone.utc).isoformat()
    total = 0

    for source in sources:
        print(f"\n{source['name']}  ({source['shelter']}, {source['city']}, {source['state']})")

        since = None if args.full_refresh else local_watermark(source)
        print(f"  mode: {'full refresh' if since is None else f'incremental since {since[:10]}'}")

        rows = pull(source, since)

        if not rows:
            print("  no new rows")
            continue

        path = write(source, rows, extracted_at)
        size_kb = path.stat().st_size / 1024
        print(f"  wrote {len(rows):,} rows to {path} [{size_kb:,.0f} KB]")
        total += len(rows)

    print(f"\nDone. {total:,} rows extracted across {len(sources)} source(s).")


if __name__ == "__main__":
    main()
