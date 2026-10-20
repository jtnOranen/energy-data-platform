# storage

ADLS Gen2 storage account (`is_hns_enabled = true`) with a `landing` container for raw
ingestion data. See `docs/data-model.md` for how the landing container feeds the bronze
layer, and `docs/architecture.md` for the path convention under `landing/`.
