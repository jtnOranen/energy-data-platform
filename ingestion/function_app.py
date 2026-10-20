"""Azure Functions entry point: one hourly timer per source (docs/phases/phase-1-ingestion.md)."""

import os
from datetime import UTC, datetime

import azure.functions as func

from energy_ingest.fingrid import FingridClient
from energy_ingest.fmi import FmiClient
from energy_ingest.landing import Landing
from energy_ingest.run import ingest_fingrid, ingest_fmi
from energy_ingest.window import fetch_window

app = func.FunctionApp()

# NCRONTAB (sec min hour day month weekday), UTC. Sources are staggered so their logs
# don't interleave; ENTSO-E is added once its token is available.


@app.timer_trigger(schedule="0 5 * * * *", arg_name="timer", run_on_startup=False)
def fingrid_hourly(timer: func.TimerRequest) -> None:
    now = datetime.now(UTC)
    start, end = fetch_window(now)
    with FingridClient(os.environ["FINGRID_API_KEY"]) as client:
        ingest_fingrid(client, Landing.from_env(), start, end, ingested_at=now)


@app.timer_trigger(schedule="0 10 * * * *", arg_name="timer", run_on_startup=False)
def fmi_hourly(timer: func.TimerRequest) -> None:
    now = datetime.now(UTC)
    start, end = fetch_window(now)
    with FmiClient() as client:
        ingest_fmi(client, Landing.from_env(), start, end, ingested_at=now)
