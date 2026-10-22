"""Local Spark for the bronze tests.

Spark needs Java. CI has it; without it (e.g. the owner's Windows machine) the tests are skipped
rather than failing, so `uv run pytest` still works everywhere.
"""

import os
import shutil
from pathlib import Path

import pytest

from .bronze_helpers import FIXTURES, INGESTED_AT, WINDOW


@pytest.fixture(scope="session")
def spark():
    if not (shutil.which("java") or os.environ.get("JAVA_HOME")):
        pytest.skip("Spark tests need Java; they run in CI")
    sql = pytest.importorskip("pyspark.sql", reason="needs the spark group: uv sync --group spark")
    session = (
        sql.SparkSession.builder.master("local[1]")
        .config("spark.sql.session.timeZone", "UTC")
        .config("spark.ui.enabled", "false")
        .config("spark.sql.shuffle.partitions", "1")
        .getOrCreate()
    )
    yield session
    session.stop()


@pytest.fixture
def landing(tmp_path):
    """Copy a fixture into a landing-style path and return that path."""

    def copy(fixture: str, part: int = 1, key: str | None = None, text: str | None = None) -> Path:
        name = "_".join([INGESTED_AT, WINDOW, *([key] if key else []), f"p{part:03d}"])
        target = tmp_path / "yyyy=2026" / "mm=10" / "dd=22" / f"{name}{Path(fixture).suffix}"
        target.parent.mkdir(parents=True, exist_ok=True)
        if text is None:
            shutil.copyfile(FIXTURES / fixture, target)
        else:
            target.write_text(text, encoding="utf-8")
        return target

    return copy
