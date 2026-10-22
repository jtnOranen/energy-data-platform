"""Metadata columns every bronze table gets, derived from the landing file path.

Landing file names are `<ingested_at>_<start>_<end>[_<key>]_p<part>.<ext>` with UTC stamps like
`20261022T061500Z` (see `energy_ingest.landing`).
"""

from pyspark.sql import Column, DataFrame
from pyspark.sql import functions as F

METADATA_COLUMNS = ["_ingested_at", "_source_file", "_loaded_at"]
RESCUED_DATA_COLUMN = "_rescued_data"

_STAMP = r"\d{8}T\d{6}Z"
_INGESTED_AT = rf"/({_STAMP})_[^/]+$"
_KEY = rf"/{_STAMP}_{_STAMP}_{_STAMP}_([^_/]+)_p\d+\.\w+$"


def with_metadata(df: DataFrame) -> DataFrame:
    """Add `_source_file`, `_ingested_at` and `_loaded_at` from the file metadata.

    Call this on the DataFrame straight from the reader: `_metadata` is a hidden column of the
    file source and is gone after the first select or explode.
    """
    path = F.col("_metadata.file_path")
    return df.withColumns(
        {
            "_source_file": path,
            # The fetch time, not the load time: it's when the data was true at the source, which
            # is what silver dedupes on. `X` parses the trailing Z as UTC.
            "_ingested_at": F.to_timestamp(
                F.regexp_extract(path, _INGESTED_AT, 1), "yyyyMMdd'T'HHmmssX"
            ),
            "_loaded_at": F.current_timestamp(),
        }
    )


def file_key() -> Column:
    """The optional `<key>` part of the file name, e.g. the FMI station; empty if absent."""
    return F.regexp_extract(F.col("_source_file"), _KEY, 1)


def passthrough(df: DataFrame) -> list[str]:
    """Columns every transform carries to the output: metadata, plus rescued data if present.

    Auto Loader adds `_rescued_data` for fields the schema doesn't expect; batch reads in the
    tests don't have it.
    """
    extra = [RESCUED_DATA_COLUMN] if RESCUED_DATA_COLUMN in df.columns else []
    return [*METADATA_COLUMNS, *extra]
