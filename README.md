# OPTIHEAT — Adaptive MPC for a Real Heat Pump (MATLAB/Simulink track)

Price-responsive heat-pump control for a real 5-unit residential building
(Virchowstr. 6, Langenhagen), developed for a Master's thesis under the
BMWK 8th Energy Research Programme. This repo is the MATLAB/Simulink
Adaptive MPC track; a companion Python/RL track exists separately.

**Goal:** replace pure setpoint-tracking ("hold 20°C") with a controller
that shifts heat-pump load into cheap electricity-price hours using the
building's thermal mass and a buffer tank, without losing comfort.

**Current status (2026-08-19):** the full pipeline is implemented and
runs — real building physics, real IDM ALM 4-12 heat-pump data, real
Langenhagen weather, real 2025 Tibber day-ahead prices, a 500 L buffer
tank with a thermostatic-valve model, and a 2-state (room + tank)
Adaptive MPC with price wired into its objective. It does not yet
reliably beat the market average price — see
[`OPTIHEAT_PROJECT_STATUS.md`](OPTIHEAT_PROJECT_STATUS.md) §5 item 1 for
a fully traced explanation of why (a specific, understood limitation of
the Adaptive MPC architecture, not an open mystery) and what's needed to
close the gap. **That file is the up-to-date source of truth** for
implementation status, known issues, and next steps; this README is just
an entry point.

## Quick start

```matlab
addpath(genpath(pwd))
init_adaptive_mpc      % builds mpcobj + plant_d0, loads/slices weather+price, sets StopTime
analyze_run             % runs the sim, logs to RESULTS/run_<timestamp>/, computes real cost, plots
```

`init_adaptive_mpc.m` has a `startDate` / `simulationDays` pair near the
top — set `simulationDays` to 1-2 for fast iteration (well under a
minute per run on this machine) or longer for a final validation run.

## Repository map

| Path | What it is |
|---|---|
| `A-MPC/` | Controller setup (`init_adaptive_mpc.m`), the MPC's per-step prediction model (`run_adaptive_mpc_hp.m`, mirrors the live Simulink block), and the run/analysis pipeline (`analyze_run.m`) |
| `HEATPUMP/` | Real IDM AERO ALM 4-12 datasheet physics, Heizgrenze (heating-limit) gate, heating curve |
| `SIM-MODEL/` | `HouseHeatingSystem.slx` (the model) and the MATLAB functions that build its adaptive plant matrices |
| `DATA/` | Real 2025 Langenhagen weather and Tibber electricity prices, 15-minute resolution |
| `RESULTS/` | Per-run output (`console.log`, `results.txt`/`.mat`, plots) — untracked, one folder per `analyze_run` call |
| `OPTIHEAT_PROJECT_STATUS.md` | **Main, current project status doc** — read this first |
| `BUFFER_TANK.md` | Buffer tank hardware, physics, and TRV valve model deep-dive |

## Full status

See [`OPTIHEAT_PROJECT_STATUS.md`](OPTIHEAT_PROJECT_STATUS.md) for what's
implemented, what's known to be wrong or incomplete, and prioritised next
steps. See [`BUFFER_TANK.md`](BUFFER_TANK.md) for the buffer tank and TRV
model specifically.
