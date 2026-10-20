"""Raw files in the ADLS `landing` container."""

import os
from datetime import UTC, datetime

from azure.identity import DefaultAzureCredential
from azure.storage.blob import ContainerClient, ContentSettings

CONTENT_TYPES = {"json": "application/json", "xml": "application/xml"}


def _stamp(value: datetime) -> str:
    return value.astimezone(UTC).strftime("%Y%m%dT%H%M%SZ")


def blob_path(
    source: str,
    dataset: str,
    ingested_at: datetime,
    start: datetime,
    end: datetime,
    part: int,
    ext: str,
    key: str | None = None,
) -> str:
    """Build `<source>/<dataset>/yyyy=/mm=/dd=/<ingested>_<start>_<end>[_<key>]_p<part>.<ext>`.

    The date partition is the ingestion date in UTC. The file name carries the fetch window and
    part number, so every response gets its own blob and nothing is ever overwritten.
    """
    if ingested_at.tzinfo is None:
        raise ValueError("ingested_at must be timezone-aware")
    day = ingested_at.astimezone(UTC)
    name = "_".join(
        [_stamp(ingested_at), _stamp(start), _stamp(end), *([key] if key else []), f"p{part:03d}"]
    )
    return f"{source}/{dataset}/yyyy={day:%Y}/mm={day:%m}/dd={day:%d}/{name}.{ext}"


class Landing:
    """Writes raw response bytes unchanged."""

    def __init__(self, container: ContainerClient) -> None:
        self._container = container

    @classmethod
    def from_env(cls) -> "Landing":
        # In Azure this is the function's managed identity; locally it's the az login session.
        container = ContainerClient(
            account_url=os.environ["LANDING_BLOB_ENDPOINT"],
            container_name=os.environ["LANDING_CONTAINER"],
            credential=DefaultAzureCredential(),
        )
        return cls(container)

    def write(self, path: str, data: bytes) -> None:
        ext = path.rsplit(".", 1)[-1]
        self._container.upload_blob(
            name=path,
            data=data,
            overwrite=False,
            content_settings=ContentSettings(content_type=CONTENT_TYPES.get(ext)),
        )
