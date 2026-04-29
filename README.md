# Cumulus Workspace

This workspace is split into app folders:

- `frontend/` for the web app
- `backend/` for the FastAPI service and shared Python package
- `ml/` for the machine learning workspace covering data registration, training, calibration, evaluation, and model artifacts

The current primary user-facing workflow is the Ghana seasonal advisory map. The frontend renders backend-published classified seasonal products, while ERA5 and GFS remain backend source options and station data is used for training/calibration rather than as a direct frontend layer.

## Common commands

From the workspace root:

```powershell
python -m pip install -e .\backend[dev]
cmd /c npm install --prefix .\frontend
python .\ml\scripts\download_era5.py --from-local-path .\backend\data\sample_forecast_smoke.nc --start-date 2024-01-01 --end-date 2024-01-14
python .\ml\scripts\download_gfs.py --from-local-path .\backend\data\sample_forecast_smoke.nc
python .\ml\scripts\train_baseline.py --forecast-source era5
python .\ml\scripts\check_data_sources.py --require-source era5 --require-station-data
powershell -ExecutionPolicy Bypass -File .\scripts\start-local.ps1
```

## Local dev server notes

Use the repo-root helper when you want both servers managed together:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-local.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\stop-local.ps1
```

The combined launcher starts the backend on `http://127.0.0.1:8000` and the frontend on `http://127.0.0.1:3000`, records PIDs under `.cumulus-local/pids.json`, and writes logs under `.cumulus-local/logs`. It refuses to start when either port is already listening and prints the owning PID. Add `-ForceRestart` only when replacing a detected local Cumulus backend or frontend process.

For foreground servers with visible crash output, use the individual helpers:

```powershell
powershell -ExecutionPolicy Bypass -File .\backend\scripts\start-backend-local.ps1
powershell -ExecutionPolicy Bypass -File .\frontend\start-frontend-local.ps1
```

Chrome requests to `/.well-known/appspecific/com.chrome.devtools.json` can return 404 during local development; that is browser/devtools probing and not an app failure. Next.js may compile `/_not-found` in dev, React StrictMode may duplicate initial frontend requests, and Leaflet map tile requests are expected while the map is visible.

## Layout

- `backend/configs` holds backend runtime configuration.
- `backend/data` holds serving-local assets such as the smoke forecast and nationwide cache outputs.
- `ml/data/raw` holds source manifests and station truth.
- `ml/data/artifacts` holds model, bias, and evaluation outputs.

See `backend/README.md`, `ml/README.md`, and `frontend/README.md` for app-specific details.
