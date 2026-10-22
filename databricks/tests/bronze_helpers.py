"""Helpers for the bronze tests. This directory is a package (`__init__.py`) so its conftest doesn't
shadow the ingestion tests' `conftest` module, which they import from."""

from pathlib import Path

# The ingestion's recorded API responses: exactly what lands in the landing container.
FIXTURES = Path(__file__).resolve().parents[2] / "ingestion" / "tests" / "fixtures"

INGESTED_AT = "20261022T061500Z"
WINDOW = "20261020T060000Z_20261022T060000Z"


def read_bronze(spark, table, path):
    """Batch-read files the way the job's stream does (same format, options and schema)."""
    from energy_bronze.metadata import with_metadata

    raw = (
        spark.read.format(table.file_format)
        .options(**table.options)
        .schema(table.schema)
        .load(str(path))
    )
    return table.transform(with_metadata(raw))
