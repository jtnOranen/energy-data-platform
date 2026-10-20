from datetime import UTC, datetime

import pytest

from conftest import FakeLanding
from energy_ingest import fingrid, fmi
from energy_ingest.run import ingest_fingrid, ingest_fmi
from energy_ingest.transport import Page, SourceError

START = datetime(2025, 1, 1, tzinfo=UTC)
END = datetime(2025, 1, 3, tzinfo=UTC)
NOW = datetime(2025, 1, 3, 0, 5, tzinfo=UTC)


class StubFingrid:
    def __init__(self, failing: set[int] = frozenset()):
        self.failing = failing

    def fetch(self, dataset_id, start, end):
        if dataset_id in self.failing:
            raise SourceError(f"dataset {dataset_id} down")
        yield Page(1, f'{{"dataset": {dataset_id}}}'.encode(), 1)
        yield Page(2, b"{}", 0)


def test_writes_every_page_of_every_dataset_unchanged():
    landing = FakeLanding()
    assert ingest_fingrid(StubFingrid(), landing, START, END, NOW) == 2 * len(fingrid.DATASETS)
    wind = [p for p in landing.files if p.startswith("fingrid/wind_production/")]
    assert len(wind) == 2
    assert landing.files[sorted(wind)[0]] == b'{"dataset": 75}'


def test_one_failing_dataset_does_not_stop_the_others():
    landing = FakeLanding()
    with pytest.raises(SourceError, match="1 failed"):
        ingest_fingrid(StubFingrid(failing={124}), landing, START, END, NOW)
    assert any(p.startswith("fingrid/wind_production/") for p in landing.files)
    assert any(p.startswith("fingrid/production/") for p in landing.files)
    assert not any(p.startswith("fingrid/consumption/") for p in landing.files)


class StubFmi:
    def fetch(self, fmisid, start, end):
        yield Page(1, b"<xml/>", 0)


def test_fmi_writes_one_file_per_station_with_station_in_name():
    landing = FakeLanding()
    assert ingest_fmi(StubFmi(), landing, START, END, NOW) == len(fmi.STATIONS)
    assert all(p.startswith("fmi/observations/yyyy=2025/mm=01/dd=03/") for p in landing.files)
    assert any("_100968_p001.xml" in p for p in landing.files)
