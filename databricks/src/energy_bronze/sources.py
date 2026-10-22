"""One definition per bronze table: where its files are, how to read them, and how to flatten them.

Schemas are explicit rather than inferred. The source formats are known and verified
(docs/data-sources.md), so an explicit schema means a new or renamed field can't break the stream;
Auto Loader puts anything unexpected in `_rescued_data` instead. Every leaf is a string: bronze
keeps the source values exactly as sent, and staging types them.

The only transformation is exploding nested arrays into rows (a 20,000-record Fingrid page as one
row would be useless to query) and giving the flattened XML fields plain names.
"""

from collections.abc import Callable
from dataclasses import dataclass, field

from pyspark.sql import DataFrame
from pyspark.sql import functions as F
from pyspark.sql.types import ArrayType, StringType, StructField, StructType

from energy_bronze.metadata import file_key, passthrough


def _struct(*names: str) -> StructType:
    return StructType([StructField(name, StringType()) for name in names])


@dataclass(frozen=True)
class BronzeTable:
    name: str  # table name in the bronze schema
    landing_path: str  # relative to the root of the landing container
    file_format: str  # Spark / Auto Loader format
    schema: StructType
    transform: Callable[[DataFrame], DataFrame]
    options: dict[str, str] = field(default_factory=dict)


# --- Fingrid: JSON page {"data": [{datasetId, startTime, endTime, value}], "pagination": {...}} ---

FINGRID_SCHEMA = StructType(
    [StructField("data", ArrayType(_struct("datasetId", "startTime", "endTime", "value")))]
)


def flatten_fingrid(df: DataFrame) -> DataFrame:
    """One row per record in `data`, with Fingrid's own field names."""
    keep = passthrough(df)
    records = df.select(F.explode("data").alias("r"), *keep)
    return records.select("r.datasetId", "r.startTime", "r.endTime", "r.value", *keep)


def _fingrid(name: str) -> BronzeTable:
    return BronzeTable(
        name=f"fingrid_{name}",
        landing_path=f"fingrid/{name}/",
        file_format="json",
        schema=FINGRID_SCHEMA,
        transform=flatten_fingrid,
        options={"multiLine": "true"},
    )


# --- ENTSO-E: Publication_MarketDocument > TimeSeries > Period > Point ---

ENTSOE_SCHEMA = StructType(
    [
        StructField("mRID", StringType()),
        StructField("revisionNumber", StringType()),
        StructField(
            "TimeSeries",
            ArrayType(
                StructType(
                    [
                        StructField("mRID", StringType()),
                        StructField(
                            "Period",
                            ArrayType(
                                StructType(
                                    [
                                        StructField("timeInterval", _struct("start", "end")),
                                        StructField("resolution", StringType()),
                                        StructField(
                                            "Point", ArrayType(_struct("position", "price.amount"))
                                        ),
                                    ]
                                )
                            ),
                        ),
                    ]
                )
            ),
        ),
    ]
)


def flatten_entsoe(df: DataFrame) -> DataFrame:
    """One row per `Point`. Positions omitted by curve type A03 stay omitted; staging fills them."""
    keep = passthrough(df)
    series = df.select(
        F.col("mRID").alias("document_mrid"),
        F.col("revisionNumber").alias("revision_number"),
        F.explode("TimeSeries").alias("ts"),
        *keep,
    )
    periods = series.select(
        "document_mrid",
        "revision_number",
        F.col("ts.mRID").alias("time_series_mrid"),
        F.explode("ts.Period").alias("p"),
        *keep,
    )
    points = periods.select(
        "document_mrid",
        "revision_number",
        "time_series_mrid",
        F.col("p.timeInterval.start").alias("period_start"),
        F.col("p.timeInterval.end").alias("period_end"),
        F.col("p.resolution").alias("resolution"),
        F.explode("p.Point").alias("pt"),
        *keep,
    )
    return points.select(
        "document_mrid",
        "revision_number",
        "time_series_mrid",
        "period_start",
        "period_end",
        "resolution",
        F.col("pt.position").alias("position"),
        F.col("pt.`price.amount`").alias("price_amount"),
        *keep,
    )


# --- FMI: WFS timevaluepair, one wml2:MeasurementTimeseries per parameter ---

FMI_SCHEMA = StructType(
    [
        # e.g. obs-obs-1-1-t2m: the parameter is the last part
        StructField("_gml:id", StringType()),
        StructField(
            "wml2:point",
            ArrayType(
                StructType([StructField("wml2:MeasurementTVP", _struct("wml2:time", "wml2:value"))])
            ),
        ),
    ]
)


def flatten_fmi(df: DataFrame) -> DataFrame:
    """One row per time-value pair. The station comes from the file name key, which the ingestion
    sets to the FMISID it queried; `value` stays a string so `NaN` survives to staging."""
    keep = passthrough(df)
    points = df.select(
        file_key().alias("fmisid"),
        F.regexp_extract(F.col("`_gml:id`"), r"-([^-]+)$", 1).alias("parameter"),
        F.explode("`wml2:point`").alias("pt"),
        *keep,
    )
    return points.select(
        "fmisid",
        "parameter",
        F.col("pt.`wml2:MeasurementTVP`.`wml2:time`").alias("time"),
        F.col("pt.`wml2:MeasurementTVP`.`wml2:value`").alias("value"),
        *keep,
    )


SOURCES: dict[str, list[BronzeTable]] = {
    "fingrid": [_fingrid("wind_production"), _fingrid("consumption"), _fingrid("production")],
    "entsoe": [
        BronzeTable(
            name="entsoe_day_ahead_price",
            landing_path="entsoe/day_ahead_price/",
            file_format="xml",
            schema=ENTSOE_SCHEMA,
            transform=flatten_entsoe,
            options={"rowTag": "Publication_MarketDocument"},
        )
    ],
    "fmi": [
        BronzeTable(
            name="fmi_observations",
            landing_path="fmi/observations/",
            file_format="xml",
            schema=FMI_SCHEMA,
            transform=flatten_fmi,
            options={"rowTag": "wml2:MeasurementTimeseries"},
        )
    ],
}
