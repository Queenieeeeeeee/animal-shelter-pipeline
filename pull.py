#!/usr/bin/env python3
"""
Daily snapshot of adoptable animals from the Petfinder API.

Writes one gzipped JSONL file per day to data/raw/YYYY-MM-DD.jsonl.gz.
Every line is one animal exactly as the API reported it that day.

Why daily snapshots: the Petfinder API only ever shows the CURRENT state of
each animal. It does not expose history. Taking a snapshot every day is what
creates the history -- an animal appearing on 2026-10-01 and gone by
2026-10-14 is how we learn it took ~13 days to be adopted. Without the daily
pull there is nothing to model later.
"""

import gzip
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import requests

# --- Configuration -----------------------------------------------------------

# Petfinder's `location` accepts "City, State", a postal code, or lat,lng.
# distance is capped at 500 miles by the API. Phoenix + 500mi covers all of
# Arizona and spills into neighbouring states, which is fine -- state is
# recorded per animal so the scope can be narrowed at modelling time.
LOCATION = "Phoenix, AZ"
DISTANCE = 500
TYPES = ["dog", "cat"]

PAGE_SIZE = 100        # API maximum
MAX_PAGES = 100        # safety stop; the API caps deep pagination anyway
SLEEP_BETWEEN = 0.4    # be polite; rate limits are not published
MAX_RETRIES = 4

TOKEN_URL = "https://api.petfinder.com/v2/oauth2/token"
ANIMALS_URL = "https://api.petfinder.com/v2/animals"

OUT_DIR = Path("data/raw")
USER_AGENT = "shelter-throughput-pipeline/1.0 (portfolio project)"


# --- API -----------------------------------------------------------------------

def get_token(key: str, secret: str) -> str:
    """Exchange the API key and secret for a bearer token (valid ~1 hour)."""
    resp = requests.post(
        TOKEN_URL,
        data={
            "grant_type": "client_credentials",
            "client_id": key,
            "client_secret": secret,
        },
        headers={"User-Agent": USER_AGENT},
        timeout=30,
    )
    if resp.status_code == 401:
        sys.exit("Authentication failed. Check PETFINDER_KEY and PETFINDER_SECRET.")
    resp.raise_for_status()
    return resp.json()["access_token"]


def fetch_page(token: str, animal_type: str, page: int) -> dict:
    """Fetch one page, retrying on rate limits and transient server errors."""
    params = {
        "type": animal_type,
        "location": LOCATION,
        "distance": DISTANCE,
        "limit": PAGE_SIZE,
        "page": page,
        "sort": "recent",
    }
    headers = {"Authorization": f"Bearer {token}", "User-Agent": USER_AGENT}

    for attempt in range(MAX_RETRIES):
        resp = requests.get(ANIMALS_URL, params=params, headers=headers, timeout=60)

        if resp.status_code == 200:
            return resp.json()

        # 429 = rate limited, 5xx = transient. Back off and retry.
        if resp.status_code == 429 or resp.status_code >= 500:
            wait = 2 ** attempt * 5
            print(f"  HTTP {resp.status_code} on {animal_type} p{page}; "
                  f"retrying in {wait}s (attempt {attempt + 1}/{MAX_RETRIES})")
            time.sleep(wait)
            continue

        # Anything else (400, 403) is a real problem -- surface it.
        resp.raise_for_status()

    raise RuntimeError(f"Gave up on {animal_type} page {page} after {MAX_RETRIES} attempts")


# --- Shaping -------------------------------------------------------------------

def dig(obj, *keys, default=None):
    """Safely walk nested dicts; the API omits keys rather than sending null."""
    for key in keys:
        if not isinstance(obj, dict):
            return default
        obj = obj.get(key)
        if obj is None:
            return default
    return obj


DESCRIPTION_CHARS = 500  # how much of the shelter's write-up to keep


def shape(animal: dict, snapshot_date: str, pulled_at: str) -> dict:
    """
    Keep the analytical fields and trim the bulk.

    `description` is the shelter's free-text write-up. Breed, size, age and
    temperament already arrive as their own structured fields, so the text is
    not needed to identify the animal -- what it uniquely carries is backstory,
    behavioural notes and medical detail. The first 500 characters hold most of
    that while keeping daily files roughly a third the size of storing it whole.
    Full length is recorded separately so listing thoroughness stays measurable.
    """
    photos = animal.get("photos") or []
    description = (animal.get("description") or "").strip()

    return {
        # snapshot identity -- the two fields that make this a time series
        "snapshot_date": snapshot_date,
        "pulled_at": pulled_at,

        # animal identity
        "animal_id": animal.get("id"),
        "organization_id": animal.get("organization_id"),
        "url": animal.get("url"),

        # what it is
        "type": animal.get("type"),
        "species": animal.get("species"),
        "breed_primary": dig(animal, "breeds", "primary"),
        "breed_secondary": dig(animal, "breeds", "secondary"),
        "breed_mixed": dig(animal, "breeds", "mixed"),
        "breed_unknown": dig(animal, "breeds", "unknown"),
        "color_primary": dig(animal, "colors", "primary"),
        "age": animal.get("age"),
        "gender": animal.get("gender"),
        "size": animal.get("size"),
        "coat": animal.get("coat"),

        # care attributes -- candidate drivers of time-to-adoption
        "spayed_neutered": dig(animal, "attributes", "spayed_neutered"),
        "house_trained": dig(animal, "attributes", "house_trained"),
        "declawed": dig(animal, "attributes", "declawed"),
        "special_needs": dig(animal, "attributes", "special_needs"),
        "shots_current": dig(animal, "attributes", "shots_current"),
        "good_with_children": dig(animal, "environment", "children"),
        "good_with_dogs": dig(animal, "environment", "dogs"),
        "good_with_cats": dig(animal, "environment", "cats"),
        "tags": animal.get("tags") or [],

        # listing quality -- does a better listing get adopted faster?
        "photo_count": len(photos),
        "video_count": len(animal.get("videos") or []),
        "has_description": bool(description),
        "description_length": len(description),
        "description_truncated": len(description) > DESCRIPTION_CHARS,
        "description_excerpt": description[:DESCRIPTION_CHARS] or None,

        # status -- the field the SCD2 snapshot will track
        "status": animal.get("status"),
        "published_at": animal.get("published_at"),
        "status_changed_at": animal.get("status_changed_at"),

        # where
        "city": dig(animal, "contact", "address", "city"),
        "state": dig(animal, "contact", "address", "state"),
        "postcode": dig(animal, "contact", "address", "postcode"),
        "distance_miles": animal.get("distance"),
    }


# --- Main ----------------------------------------------------------------------

def main() -> None:
    key = os.environ.get("PETFINDER_KEY")
    secret = os.environ.get("PETFINDER_SECRET")
    if not key or not secret:
        sys.exit("Missing PETFINDER_KEY / PETFINDER_SECRET. See .env.example.")

    now = datetime.now(timezone.utc)
    snapshot_date = now.strftime("%Y-%m-%d")
    pulled_at = now.isoformat()

    token = get_token(key, secret)
    print(f"Snapshot {snapshot_date} -- {LOCATION} within {DISTANCE} miles")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out_path = OUT_DIR / f"{snapshot_date}.jsonl.gz"

    seen_ids: set = set()
    written = 0
    duplicates = 0

    with gzip.open(out_path, "wt", encoding="utf-8") as fh:
        for animal_type in TYPES:
            page = 1
            type_count = 0

            while page <= MAX_PAGES:
                payload = fetch_page(token, animal_type, page)
                animals = payload.get("animals") or []
                if not animals:
                    break

                for animal in animals:
                    animal_id = animal.get("id")
                    # The API can return the same animal on adjacent pages when
                    # listings shift mid-pull. One row per animal per day.
                    if animal_id in seen_ids:
                        duplicates += 1
                        continue
                    seen_ids.add(animal_id)
                    fh.write(json.dumps(shape(animal, snapshot_date, pulled_at),
                                        ensure_ascii=False) + "\n")
                    written += 1
                    type_count += 1

                total_pages = dig(payload, "pagination", "total_pages", default=1)
                if page >= total_pages:
                    break

                page += 1
                time.sleep(SLEEP_BETWEEN)

            print(f"  {animal_type}: {type_count} records across {page} page(s)")

    size_kb = out_path.stat().st_size / 1024
    print(f"Wrote {written} records ({duplicates} duplicates skipped) "
          f"to {out_path} [{size_kb:.0f} KB]")

    if written == 0:
        sys.exit("No records written -- failing so the scheduled run is visibly red.")


if __name__ == "__main__":
    main()
