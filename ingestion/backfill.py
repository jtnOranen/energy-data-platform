"""Load history into landing, using the same clients and write path as the timer functions.

Run locally as the owner (needs `az login`, Key Vault Secrets Officer/User on the vault and
Storage Blob Data Contributor on the landing container):

    uv run python ingestion/backfill.py --storage-account <name> --key-vault <name>

The names carry Terraform's random suffix; see the README for how to look them up. Each source
is chunked to its API's limits by its client (Fingrid pages of 20,000 rows, ENTSO-E 365 days,
FMI 168 hours) and keeps the same rate limits as the hourly runs. Re-running is safe: files are
never overwritten, and downstream deduplicates.
"""

import argparse
import logging
import os
import sys
from datetime import UTC, datetime

from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

from energy_ingest.entsoe import EntsoeClient
from energy_ingest.fingrid import FingridClient
from energy_ingest.fmi import FmiClient
from energy_ingest.landing import Landing
from energy_ingest.run import ingest_entsoe, ingest_fingrid, ingest_fmi
from energy_ingest.window import fetch_window

SOURCES = ("fingrid", "entsoe", "fmi")

log = logging.getLogger("backfill")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--storage-account", required=True, help="ADLS account with landing")
    parser.add_argument("--key-vault", required=True, help="Key Vault holding the API keys")
    parser.add_argument("--source", choices=[*SOURCES, "all"], default="all")
    parser.add_argument(
        "--start",
        type=lambda s: datetime.fromisoformat(s).replace(tzinfo=UTC),
        default=datetime(2024, 1, 1, tzinfo=UTC),
        help="UTC date or datetime, default 2024-01-01",
    )
    parser.add_argument(
        "--end",
        type=lambda s: datetime.fromisoformat(s).replace(tzinfo=UTC),
        default=None,
        help="UTC date or datetime, default: the last full hour",
    )
    args = parser.parse_args(argv)
    args.end = args.end or fetch_window(datetime.now(UTC))[1]
    if args.end <= args.start:
        parser.error("--end must be after --start")
    args.sources = list(SOURCES) if args.source == "all" else [args.source]
    return args


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    logging.getLogger("azure").setLevel(logging.WARNING)
    args = parse_args(argv)
    os.environ["LANDING_BLOB_ENDPOINT"] = f"https://{args.storage_account}.blob.core.windows.net/"
    os.environ.setdefault("LANDING_CONTAINER", "landing")

    credential = DefaultAzureCredential()
    secrets = SecretClient(f"https://{args.key_vault}.vault.azure.net/", credential)
    landing = Landing.from_env()
    ingested_at = datetime.now(UTC)
    log.info("backfill sources=%s start=%s end=%s", args.sources, args.start, args.end)

    failed = []
    for source in args.sources:
        try:
            if source == "fingrid":
                with FingridClient(secrets.get_secret("fingrid-api-key").value) as client:
                    n = ingest_fingrid(client, landing, args.start, args.end, ingested_at)
            elif source == "entsoe":
                with EntsoeClient(secrets.get_secret("entsoe-token").value) as client:
                    n = ingest_entsoe(client, landing, args.start, args.end, ingested_at)
            else:
                with FmiClient() as client:
                    n = ingest_fmi(client, landing, args.start, args.end, ingested_at)
            log.info("backfill source=%s files=%s", source, n)
        except Exception:  # keep going with the other sources, report at the end
            log.exception("backfill source=%s failed", source)
            failed.append(source)
    if failed:
        log.error("backfill failed for: %s", ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
