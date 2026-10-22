import json
import re
from datetime import UTC, datetime

import pytest

# energy_bronze imports pyspark, which only the `spark` dependency group installs.
pytest.importorskip("pyspark", reason="needs the spark group: uv sync --group spark")

from energy_bronze.metadata import METADATA_COLUMNS  # noqa: E402
from energy_bronze.sources import SOURCES  # noqa: E402

from .bronze_helpers import FIXTURES, read_bronze  # noqa: E402


def table(name):
    return next(t for tables in SOURCES.values() for t in tables if t.name == name)


def test_every_source_table_is_defined():
    names = {t.name for tables in SOURCES.values() for t in tables}
    assert names == {
        "fingrid_wind_production",
        "fingrid_consumption",
        "fingrid_production",
        "entsoe_day_ahead_price",
        "fmi_observations",
    }


def test_fingrid_one_row_per_record_with_source_fields(spark, landing):
    page1 = landing("fingrid_75_page1.json", part=1)
    landing("fingrid_75_page2.json", part=2)
    expected = sum(
        len(json.loads((FIXTURES / f).read_text())["data"])
        for f in ("fingrid_75_page1.json", "fingrid_75_page2.json")
    )

    df = read_bronze(spark, table("fingrid_wind_production"), page1.parent)

    assert df.columns == ["datasetId", "startTime", "endTime", "value", *METADATA_COLUMNS]
    assert df.count() == expected
    first = df.filter(df.startTime == "2025-01-01T01:45:00.000Z").first()
    # Values are kept as the exact text Fingrid sent; staging types them.
    assert first.datasetId == "75"
    assert first.endTime == "2025-01-01T02:00:00.000Z"
    assert first.value == "2260.8"


def test_metadata_comes_from_the_file_name(spark, landing):
    path = landing("fingrid_75_page1.json")

    row = read_bronze(spark, table("fingrid_consumption"), path).first()

    assert row._ingested_at == datetime(2026, 10, 22, 6, 15, tzinfo=UTC).replace(tzinfo=None)
    assert row._source_file.endswith(path.name)
    assert row._loaded_at is not None


def _points(fixture):
    return len(re.findall(r"<Point>", (FIXTURES / fixture).read_text()))


def test_entsoe_hourly_document(spark, landing):
    path = landing("entsoe_fi_20250929_pt60m.xml")

    df = read_bronze(spark, table("entsoe_day_ahead_price"), path)

    assert df.columns == [
        "document_mrid",
        "revision_number",
        "time_series_mrid",
        "period_start",
        "period_end",
        "resolution",
        "position",
        "price_amount",
        *METADATA_COLUMNS,
    ]
    # One row per Point; positions omitted by curve type A03 are not filled in bronze.
    assert df.count() == _points("entsoe_fi_20250929_pt60m.xml")
    assert {r.resolution for r in df.select("resolution").distinct().collect()} == {"PT60M"}
    first = df.filter(df.position == "1").first()
    assert first.document_mrid == "08e946631626476187cbd31001f3a424"
    assert first.revision_number == "1"
    assert (first.period_start, first.period_end) == ("2025-09-28T22:00Z", "2025-09-29T22:00Z")
    assert first.price_amount == "2.34"


def test_entsoe_quarter_hour_document(spark, landing):
    path = landing("entsoe_fi_20251002_pt15m.xml")

    df = read_bronze(spark, table("entsoe_day_ahead_price"), path)

    assert df.count() == _points("entsoe_fi_20251002_pt15m.xml")
    assert {r.resolution for r in df.select("resolution").distinct().collect()} == {"PT15M"}


def test_fmi_one_row_per_time_value_pair(spark, landing):
    path = landing("fmi_100968_1h.xml", key="100968")
    text = (FIXTURES / "fmi_100968_1h.xml").read_text()

    df = read_bronze(spark, table("fmi_observations"), path)

    assert df.columns == ["fmisid", "parameter", "time", "value", *METADATA_COLUMNS]
    assert df.count() == len(re.findall(r"<wml2:MeasurementTVP>", text))
    assert {r.parameter for r in df.select("parameter").distinct().collect()} == {"t2m", "ws_10min"}
    assert {r.fmisid for r in df.select("fmisid").distinct().collect()} == {"100968"}
    first = df.filter((df.parameter == "t2m") & (df.time == "2025-01-01T00:00:00Z")).first()
    assert first.value == "-3.6"


def test_fmi_nan_is_kept_as_text(spark, landing):
    text = (FIXTURES / "fmi_100968_1h.xml").read_text()
    with_nan = text.replace("<wml2:value>-3.6</wml2:value>", "<wml2:value>NaN</wml2:value>", 1)
    path = landing("fmi_100968_1h.xml", key="100968", text=with_nan)

    df = read_bronze(spark, table("fmi_observations"), path)

    assert df.filter(df.value == "NaN").count() == 1
