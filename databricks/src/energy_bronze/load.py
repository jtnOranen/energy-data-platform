"""Entry point of the bronze job: one Auto Loader stream per bronze table of a source.

Each stream reads the files that arrived since its last run (directory listing; a few files an hour
don't need file notifications), appends them to a managed Delta table and stops
(`availableNow`). The checkpoint remembers which files are done, so a run never reloads anything.

`--rebuild` first drops the source's tables and checkpoints, so the run reloads all of landing
(which is immutable, so this is always safe). The `bronze_rebuild` job runs it.
"""

import argparse
import logging
import shutil

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

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


def drop_table(spark: SparkSession, table: BronzeTable, catalog: str, checkpoints: str) -> None:
    """Drop the table and its checkpoint, so the next load starts from the first landing file."""
    spark.sql(f"DROP TABLE IF EXISTS {catalog}.bronze.{table.name}")
    # Volumes are mounted as a file system on serverless compute.
    shutil.rmtree(f"{checkpoints}/{table.name}", ignore_errors=True)


def latest_version(spark: SparkSession, name: str) -> int:
    """Current Delta version of a table, or -1 if it doesn't exist yet."""
    if not spark.catalog.tableExists(name):
        return -1
    return spark.sql(f"DESCRIBE HISTORY {name} LIMIT 1").first().version


def rows_written_since(spark: SparkSession, name: str, version: int) -> int:
    """Rows appended by the commits after `version`, from the Delta history."""
    history = spark.sql(f"DESCRIBE HISTORY {name}").where(F.col("version") > version)
    rows = F.col("operationMetrics").getItem("numOutputRows").cast("long")
    return history.select(F.sum(rows)).first()[0] or 0


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, choices=sorted(SOURCES))
    parser.add_argument("--catalog", default="energy")
    parser.add_argument("--landing-url", required=True, help="abfss:// root of landing")
    parser.add_argument("--checkpoints", help="default: /Volumes/<catalog>/bronze/checkpoints")
    parser.add_argument("--rebuild", action="store_true", help="drop tables first, reload all")
    args = parser.parse_args(argv)
    checkpoints = args.checkpoints or f"/Volumes/{args.catalog}/bronze/checkpoints"

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s %(message)s")
    spark = SparkSession.builder.getOrCreate()

    # One failing table doesn't stop the others; the task fails at the end (as in the ingestion).
    failed = []
    for table in SOURCES[args.source]:
        name = f"{args.catalog}.bronze.{table.name}"
        try:
            if args.rebuild:
                drop_table(spark, table, args.catalog, checkpoints)
                log.info("table=%s dropped for rebuild", table.name)
            before = latest_version(spark, name)
            load_table(spark, table, args.catalog, args.landing_url, checkpoints)
            log.info("table=%s rows=%s", table.name, rows_written_since(spark, name, before))
        except Exception:
            log.exception("table=%s failed", table.name)
            failed.append(table.name)
    if failed:
        raise SystemExit(f"bronze load failed for: {', '.join(failed)}")


if __name__ == "__main__":
    main()
