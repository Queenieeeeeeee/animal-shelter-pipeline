#!/usr/bin/env python3
"""
Load the raw snapshots in data/raw/ into BigQuery, one table per source.

GitHub is the system of record; BigQuery is a rebuildable copy for querying.
Every run rebuilds each table from scratch out of ALL snapshot files on disk:

    data/raw/sonoma/2026-10-01.ndjson.gz  -+
    data/raw/sonoma/2026-10-14.ndjson.gz  -+->  raw.sonoma  (+ _snapshot_date)
    data/raw/sonoma/2026-11-01.ndjson.gz  -+

Why rebuild instead of appending only the newest file:
  * The BigQuery sandbox has no DML (no INSERT/UPDATE/DELETE/MERGE) and
    expires every table 60 days after it is created. A full rebuild needs
    neither, and recreating the table restarts its 60-day clock.
  * It is idempotent: running it twice gives the same table, not duplicates.
  * If a table is ever lost, re-running this script restores it exactly.

Every column is loaded as STRING, matching what the Socrata API returns. Type
casting belongs in the dbt staging models, where it is visible and tested --
the same "raw stays raw" rule extract.py follows. The one exception is
_snapshot_date (DATE), which this loader adds from the file name so dbt can
tell snapshots apart.

The tables are deliberately NOT partitioned: in the sandbox a partition also
expires 60 days after its own date, so partitioning by snapshot date would
silently delete every snapshot older than two months.
"""

import argparse
import gzip
import json
import os
import re
import sys
import tempfile
from pathlib import Path

import yaml
from google.api_core.exceptions import NotFound
from google.cloud import bigquery

RAW_DIR = Path("data/raw")
SOURCES_FILE = Path("sources.yml")
DATASET = "raw"
LOCATION = "US"
SNAPSHOT_FILE = re.compile(r"^(\d{4}-\d{2}-\d{2})\.ndjson\.gz$")
BQ_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,299}$")


def load_sources() -> list[dict]:
    if not SOURCES_FILE.exists():
        sys.exit(f"{SOURCES_FILE} not found -- run from the repository root.")
    with SOURCES_FILE.open(encoding="utf-8") as fh:
        return (yaml.safe_load(fh) or {}).get("sources") or []


def snapshot_files(source_name: str) -> list[tuple[str, Path]]:
    """(snapshot_date, path) for every snapshot of a source, oldest first."""
    source_dir = RAW_DIR / source_name
    found = []
    for path in sorted(source_dir.glob("*.ndjson.gz")):
        match = SNAPSHOT_FILE.match(path.name)
        if match:
            found.append((match.group(1), path))
    return found


def as_string(value):
    """
    Socrata returns almost everything as a string already. The rare nested
    value (e.g. a geocoded location object) is kept as its JSON text rather
    than flattened, so nothing is interpreted on the way in.
    """
    if value is None or isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def build_load_file(snapshots: list[tuple[str, Path]], out_path: Path) -> tuple[list[str], int]:
    """
    Combine every snapshot into one NDJSON file ready for a load job.

    Pass 1 collects the union of column names: a field that is blank in a
    row is simply missing from Socrata's JSON, so no single row has them all.
    Pass 2 writes each row with _snapshot_date added and values as strings.
    """
    columns: set[str] = set()
    for _, path in snapshots:
        with gzip.open(path, "rt", encoding="utf-8") as fh:
            for line in fh:
                columns.update(json.loads(line).keys())

    bad = sorted(c for c in columns if not BQ_NAME.match(c))
    if bad:
        sys.exit(f"  FAILED: column names BigQuery will not accept: {bad}")
    if "_snapshot_date" in columns:
        sys.exit("  FAILED: source already has a _snapshot_date column.")

    rows = 0
    with out_path.open("w", encoding="utf-8") as out:
        for snapshot_date, path in snapshots:
            with gzip.open(path, "rt", encoding="utf-8") as fh:
                for line in fh:
                    record = {k: as_string(v) for k, v in json.loads(line).items()}
                    record["_snapshot_date"] = snapshot_date
                    out.write(json.dumps(record, ensure_ascii=False) + "\n")
                    rows += 1

    return sorted(columns), rows


def load_source(client: bigquery.Client, source: dict, project: str) -> int:
    name = source["name"]
    table_id = f"{project}.{DATASET}.{name}"
    snapshots = snapshot_files(name)
    if not snapshots:
        sys.exit(f"  FAILED: no snapshot files in {RAW_DIR / name}. Run extract.py first.")

    print(f"  {len(snapshots)} snapshot(s): {', '.join(d for d, _ in snapshots)}")

    with tempfile.TemporaryDirectory() as tmp:
        load_path = Path(tmp) / f"{name}.ndjson"
        columns, expected = build_load_file(snapshots, load_path)
        print(f"  {expected:,} rows, {len(columns)} columns")

        schema = [bigquery.SchemaField("_snapshot_date", "DATE", mode="REQUIRED")]
        schema += [bigquery.SchemaField(c, "STRING") for c in columns]

        # Drop and recreate rather than truncate, so the table is brand new and
        # its sandbox 60-day expiry starts over. If the load below then fails,
        # the run goes red and simply re-running it restores the table.
        client.delete_table(table_id, not_found_ok=True)

        job_config = bigquery.LoadJobConfig(
            source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
            schema=schema,
            write_disposition=bigquery.WriteDisposition.WRITE_EMPTY,
            max_bad_records=0,   # one unreadable row fails the whole load, loudly
        )
        with load_path.open("rb") as fh:
            job = client.load_table_from_file(fh, table_id, job_config=job_config,
                                              location=LOCATION)
        job.result()             # waits; raises if the load job failed

    loaded = client.get_table(table_id).num_rows
    if loaded != expected:
        sys.exit(f"  FAILED: wrote {expected:,} rows to the load file but "
                 f"{table_id} holds {loaded:,}.")
    print(f"  loaded {loaded:,} rows into {table_id}  OK")
    return loaded


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", help="load a single source by name")
    args = parser.parse_args()

    project = os.environ.get("GCP_PROJECT")
    if not project:
        sys.exit("Set the GCP_PROJECT environment variable to the Google Cloud project ID.")

    sources = load_sources()
    if args.source:
        sources = [s for s in sources if s["name"] == args.source]
        if not sources:
            sys.exit(f"No source named '{args.source}' in sources.yml.")

    client = bigquery.Client(project=project, location=LOCATION)
    try:
        client.get_dataset(f"{project}.{DATASET}")
    except NotFound:
        sys.exit(f"Dataset {project}.{DATASET} does not exist -- create it in the "
                 f"BigQuery console first (location {LOCATION}).")

    total = 0
    for source in sources:
        print(f"\n{source['name']}")
        total += load_source(client, source, project)

    print(f"\nDone. {total:,} rows loaded into {project}.{DATASET} "
          f"across {len(sources)} table(s).")


if __name__ == "__main__":
    main()
