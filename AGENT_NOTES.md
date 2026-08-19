# Agent Notes — read this first

> Written by Claude on 2026-08-19. Everything durable from this session
> has been folded into `OPTIHEAT_PROJECT_STATUS.md` (§4/§5/§6/§8/§9/§10)
> and `BUFFER_TANK.md` (§6/§8/§9) — **those are the source of truth now,
> this file is just a fast-orientation pointer.** The previous version of
> this file (2026-08-17) has been fully superseded and its content folded
> in; don't go looking for it.

## 1. What this session did, in one paragraph

Diagnosed why the price-weighted 2-state Adaptive MPC wasn't beating the
market mean price. Found and fixed two real bugs (Simulink `SimulationMode`
stuck on `rapid-accelerator` with no compiler present — silently killed
several 2026-08-17 runs; the MPC's own internal model didn't respect the
15°C Heizgrenze heat-pump cutoff). Traced the *remaining* gap to a specific
architectural limitation (Adaptive MPC freezes its linearization, including
compressor capacity, for the whole 24h horizon — it cannot foresee the
daily Heizgrenze cutoff coming). Tried and ruled out four tuning-only
fixes with short-run evidence; found one (small constant tank-tracking
weight) that measurably helps but doesn't fully close the gap. Full details
and the three-regime results table: `OPTIHEAT_PROJECT_STATUS.md` §5 item 1.

## 2. Current working-tree state (as of 2026-08-19 ~21:35)

**Uncommitted, modified** (not yet committed — ask the user before
committing, per standing instructions):
- `A-MPC/init_adaptive_mpc.m` — default `startDate='2025-03-15'`,
  `simulationDays=2`; `mpcobj.Weights.OV=[0.3,0.1]`; tank
  `MinECR=0.05`; comments updated throughout with the 2026-08-19 findings.
- `SIM-MODEL/getAdaptivePlant.m` — `Qmax_W` now zeroed when the Heizgrenze
  gate is closed at the current step.
- `A-MPC/apply_performance_settings.m` — checks for a C compiler before
  requesting Accelerator mode; falls back to `normal` with a warning.
- `SIM-MODEL/HouseHeatingSystem.slx` — re-saved with `SimulationMode='normal'`
  (was `rapid-accelerator`, which fails on this machine — no compiler).
- `OPTIHEAT_PROJECT_STATUS.md`, `BUFFER_TANK.md`, `README.md` — updated to
  current state.
- `A-MPC/run_adaptive_mpc_hp.m` was NOT touched this session — it was
  already in sync with the live "MPC Prediction Model" Stateflow chart
  (verified directly by reading the chart's `.Script` property and
  tracing its `T_room_C` input back to `House Thermal Network`'s real
  `Room` output — both confirmed correct).

**Untracked:** all `RESULTS/run_*` folders (build up fast, ~1 per test —
consider `.gitignore`), `slprj/`, build cache. Same as before, not touched.

## 3. If you're picking this up next

The highest-value next step is `OPTIHEAT_PROJECT_STATUS.md` §8 item 1:
close the Heizgrenze-foresight gap, either via a genuinely time-varying/
gain-scheduled prediction model, or by exposing time-varying OV bounds on
the Simulink MPC block (its mask does not currently expose that as an
inport — this needs real Simulink structural surgery, not an
`init_adaptive_mpc.m` weight change).

**Do NOT re-attempt an MV-weight-discount approach** to give the
controller foresight — tried at two strengths (0.3x and 0.03x), both
traced to do essentially nothing, and the aggressive one made the QP take
~30 min to solve a 2-day run instead of under a minute. Full trace
evidence in `OPTIHEAT_PROJECT_STATUS.md` §5 item 1, fix 4. Discounting
*cost* doesn't fix a wrong *belief* about future capacity — the
controller needs the belief itself corrected, not a cheaper price to
ignore.

**On MATLAB session behaviour this session:** `evaluate_matlab_code` calls
occasionally took a very long time (once ~30 min, once genuinely stuck
until the user manually checked MATLAB's desktop for a blocking dialog).
If a call seems to hang, check `Get-Process -Name MATLAB` CPU delta over
~15s before assuming it's broken — 0 delta with `Responding: True` means
it's idle/blocked on something (e.g. a dialog), not crashed; check the
`RESULTS/` folder timestamps too, since a run can finish on its own after
Claude's own client-side wait gives up.

## 4. Repo orientation (quick reference)

Run order: `addpath(genpath(pwd))` → `init_adaptive_mpc` → `analyze_run`.
Set `simulationDays=1` or `2` in `init_adaptive_mpc.m` for fast iteration.

```
A-MPC/init_adaptive_mpc.m     Build mpcobj (2-state, price-weighted, tank-anchored), slice weather/price, set StopTime. RUN FIRST.
A-MPC/run_adaptive_mpc_hp.m   Mirror of the live MATLAB Function/Stateflow block in the model — NOT auto-synced, edit both.
A-MPC/analyze_run.m           Runs sim, logs to RESULTS/run_<timestamp>/, computes real cost from price_ts, plots.
SIM-MODEL/HouseHeatingSystem.slx   Main model. Buffer tank + TRV valve chain live inside the HP subsystem.
SIM-MODEL/getAdaptivePlant.m       2-state ss/c2d plant (interpreted path) — TRV law + Heizgrenze-aware Qmax_W live here.
SIM-MODEL/getAdaptivePlantMats.m   Same, raw A/B/C/D matrices (codegen path) — what the live "MPC Prediction Model" chart calls.
HEATPUMP/                     Real IDM ALM 4-12 datasheet physics + heating_curve.m.
DATA/                         Real 2025 Langenhagen weather + Tibber prices, 15-min.
RESULTS/run_<timestamp>/      console.log, results.txt/.mat, plot .png/.fig per run. Untracked, gitignore candidate.
OPTIHEAT_PROJECT_STATUS.md    Main project doc — current as of 2026-08-19.
BUFFER_TANK.md                Buffer tank + TRV deep-dive — current as of 2026-08-19.
```
