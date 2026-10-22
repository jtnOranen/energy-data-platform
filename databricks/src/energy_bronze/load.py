"""Entry point of the bronze job: one Auto Loader stream per bronze table of a source.

Each stream reads the files that arrived since its last run (directory listing; a few files an hour
don't need file notifications), appends them to a managed Delta table and stops
(`availableNow`). The checkpoint remembers which files are done, so a run never reloads anything.
"""

import argparse
import logging

from pyspark.sql import SparkSession

from energy_bronze.metadata import RESCUED_DATA_COLUMN, with_metadata
from energy_bronze.sources import SOURCES, BronzeTable

log = logging.getLogger("energy_bronze")


def load_table(
    spark: SparkSession, table: BronzeTable, catalog: str, landing_url: str, checkpoints: str
) -> None:
    """Append every new file under the table's landing path to `<catalog>.bronze.<table>`."""
    stream = (
        spark.readStream.format("cloudFiles")
        .option("cloudFiles.format", table.file_format)
        .option("rescuedDataColumn", RESCUED_DATA_COLUMN)
        .options(**table.options)
        .schema(table.schema)
        .load(f"{landing_url.rstrip('/')}/{table.landing_path}")
    )
    query = (
        table.transform(with_metadata(stream))
        .writeStream.option("checkpointLocation", f"{checkpoints}/{table.name}")
        .trigger(availableNow=True)
        .toTable(f"{catalog}.bronze.{table.name}")
    )
    query.awaitTermination()


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, choices=sorted(SOURCES))
    parser.add_argument("--catalog", default="energy")
    parser.add_argument("--landing-url", required=True, help="abfss:// root of landing")
    parser.add_argument("--checkpoints", help="default: /Volumes/<catalog>/bronze/checkpoints")
    args = parser.parse_args(argv)
    checkpoints = args.checkpoints or f"/Volumes/{args.catalog}/bronze/checkpoints"

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s %(message)s")
    spark = SparkSession.builder.getOrCreate()

    # One failing table doesn't stop the others; the task fails at the end (as in the ingestion).
    failed = []
    for table in SOURCES[args.source]:
        try:
            load_table(spark, table, args.catalog, args.landing_url, checkpoints)
            log.info("table=%s loaded", table.name)
        except Exception:
            log.exception("table=%s failed", table.name)
            failed.append(table.name)
    if failed:
        raise SystemExit(f"bronze load failed for: {', '.join(failed)}")


if __name__ == "__main__":
    main()
