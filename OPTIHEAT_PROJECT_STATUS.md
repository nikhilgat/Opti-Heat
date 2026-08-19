# OPTIHEAT — Project Status & Implementation Log

> Price-responsive heat-pump control for a real multi-family building.
> Master's thesis · BMWK 8th Energy Research Programme.
> Last updated: 2026-08-19.

**Confidence legend** (used throughout): `[Certain]` = documented / hard evidence · `[Likely]` = strong inference · `[Guess]` = filling a gap, treat as a knob.

**Companion documents:** `BUFFER_TANK.md` — full detail on the 500 L buffer integration (blocks, wiring, parameter derivation, expected behaviour).

---

## 1. What this project is

Develop and compare **cost-minimising control strategies for an air-source heat pump** heating a real 5-unit residential building, using ENTSO-E day-ahead electricity prices, while holding thermal comfort. Two parallel workstreams:

1. **MATLAB / Simulink** — an **Adaptive MPC** controller driving a Simscape thermal-network plant, with real IDM heat-pump physics. *(This repo — `C:\Users\nikhi\Documents\MATLAB\MPC`.)*
2. **Python / i4b** — **Reinforcement Learning (SAC)** and a Python **MPC** baseline in a gym environment. *(Companion repos `i4b` / `i4b_reinforcement_learning` — summarised in §7 from project records, not re-read for this doc.)*

The end goal for both: replace pure setpoint-tracking with a controller that **shifts heat-pump load into cheap-price hours** using the building's thermal mass and the buffer tank, without losing comfort.

---

## 2. The building — Virchowstr. 6, 30853 Langenhagen

1963 solid-brick multi-family house, 5 apartments, renovated 2025 (KfW152: façade + roof insulation + heat pump), windows replaced 2020. No gas/boiler fallback.

| Parameter | Value | Source | Conf. |
|---|---|---|---|
| Heated floor area | 287.92 m² | Vonovia balancing sheet | [Certain] |
| **Design heat load** | **10,968 W** | Vonovia balancing sheet | [Certain] |
| — confirmed independently | "Heizkreis Q = 10,97 kW" | hydraulic scheme `LAN_Vir.6_HZ_SC_28.03.2025` | [Certain] |
| Building dims | 15.755 × 10.4 × 9 m | balancing sheet | [Certain] |
| Units | 5 | balancing sheet | [Certain] |
| Window Uw | 1.30 W/m²K | Energieausweis (2020) | [Certain] |
| Basement ceiling | 90 mm mineral wool | Energieausweis | [Certain] |
| Wall / roof U | ≈ 0.20 W/m²K | KfW152 | [Likely] |
| Room setpoint | 20 °C | radiator tables (55/45/20) | [Certain] |
| Annual heat demand (post-reno) | 30,874 kWh/a (was 50,210) | KfW152 EWA | [Certain] |

**Derived model parameters (as currently implemented):**

| Quantity | Value | Basis | Conf. |
|---|---|---|---|
| Total UA | **366 W/K** | design load ÷ 30 K (θe = −10 °C) | [soft — see below] |
| — Ventilation H_ve | 153 W/K | n = 0.6/h, V ≈ 749 m³ | [Guess] |
| — Transmission H_tr | ≈ 213 W/K | balance | [Likely] |
| Thermal capacitance C | 7.46e7 J/K (72 Wh/m²K) | solid-brick construction class | [Likely] |
| Time constant τ | ≈ 57 h | C / UA | [Likely] |
| Window area | 30.6 m² (6.5 % WWR) | back-solved to close UA | [Guess] |

### ⚠ Open calibration point — UA depends on an unconfirmed θe

UA = 366 assumes design outdoor temp **θe = −10 °C**, still **not confirmed from the documents**. Candidate values:

| θe | Implied UA | Basis |
|---|---|---|
| −10 °C | 366 W/K | current implementation |
| −12 °C | 345 W/K | envelope estimate + annual-energy check |
| −14 °C | 323 W/K | DIN EN 12831 Bbl. 1, climate zone 3 (Langenhagen) |

Note the annual-energy cross-check that supported −12 °C is **not reliable** — the Energieausweis figure mixes final energy with net heat demand and reflects pre-renovation, 2016-era assumptions. The design heat load remains the only trustworthy anchor. **Deliberately deferred**; see §8. Everything downstream (`UA`, `H_rad`, cycling thresholds) scales with this choice.

---

## 3. Repository map (`MATLAB/MPC`)

```
A-MPC/
  init_adaptive_mpc.m        Build mpcobj (2-state, price-weighted) + plant_d0, load+slice weather/price, set StopTime. RUN FIRST.
  run_adaptive_mpc_hp.m      Mirror of the live 'MPC Prediction Model' Stateflow chart in the .slx -- NOT auto-synced, edit both (verified in sync as of 2026-08-19).
  analyze_run.m              Runs sim, counts compressor starts, computes kWh + real cost, plots, writes RESULTS/run_<timestamp>/.
  apply_performance_settings.m  Optional Accelerator-mode speedup; checks for a C compiler first and falls back to 'normal' if none is configured (see §5).
HEATPUMP/
  idm_alm412_datasheet.m     Raw EN14511 performance tables (W35–W70, −20…+20 °C).
  idm_alm412_interpolants.m  Pth max/min + COP interpolants; NaN-filled grids + envelope query.
  hp_capacity_lookup.m       Scalar Pth [W] lookup; envelope warn, error on NaN. Does NOT apply the Heizgrenze gate (see §5) -- that lives one level up, in getAdaptivePlant.m and hp_heater_physics.m.
  hp_heater_physics.m        Heizgrenze gate + modulation → Heat_W, Elec_W, duty. This is what the REAL plant calls.
  heating_curve.m            Outdoor temp → supply temp + heating-limit flag (HEATING_LIMIT_C = 15, single source of truth).
SIM-MODEL/
  HouseHeatingSystem.slx     Main model: Adaptive MPC + HP subsystem (incl. buffer tank + TRV valve chain) + Simscape House.
  getAdaptivePlant.m         2-state (room + tank) linear plant as ss/c2d object (interpreted path); TRV law + Heizgrenze-aware Qmax_W live here.
  getAdaptivePlantMats.m     Same, raw A,B,C,D matrices (codegen path) -- what the live "MPC Prediction Model" chart calls.
  patch_plant_to_virchowstr6.m   One-time retarget of Simscape plant (already applied).
DATA/
  weather_langenhagen_2025.csv       15-min outdoor temp, full year (Open-Meteo). Cols: timestamp, T_out_C.
  electricity_prices_2025.csv        Tibber 2025, 15-min, EUR/kWh, German decimals.
RESULTS/run_<timestamp>/     console.log, results.txt/.mat, plot .png/.fig per run. Untracked (gitignore candidate).
BUFFER_TANK.md               Buffer-tank integration reference.
OPTIHEAT_PROJECT_STATUS.md   This file.
```

**Flagged for deletion / archiving** (identified, not yet executed): `Basic-Heater/` (superseded), `characterize_example_building.m`, `virchowstrBuildingParameters.m` (orphaned), `fix_mpc_codegen.m` (see §5), `HouseHeatingSystem.slxc` + `slprj/` (build cache), duplicate `.drawio`.

**Run order:** `addpath(genpath(pwd))` → `init_adaptive_mpc` → `analyze_run`. For fast iteration, set `simulationDays` to 1-2 in `init_adaptive_mpc.m` -- a 2-day run takes well under a minute on this machine in `normal` SimulationMode (see §5 item 10 on why `accelerator` mode is off by default here).

---

## 4. What is implemented

**Plant (the simulated house).** [Certain] A Simscape **4-mass thermal network** (air + wall + roof + window nodes) — the stock MathWorks demo, **retargeted to Virchowstr. 6** with real geometry / U-values / masses and a **ventilation leg** (153 W/K). Total plant UA ≈ 366 W/K, C = 7.46e7 J/K, τ ≈ 57 h.

**Buffer tank.** [Certain] 500 L Kermi buffer modelled inside the HP subsystem as a Simscape `Thermal Mass` (C = 2.093e6 J/K), with a `Tank Loss` leg (1.9 W/K) to a 15 °C plant room and an absolute `Temperature Sensor` exporting `Ttank`. The heat pump charges water rather than heating room air directly. **Full detail in `BUFFER_TANK.md`.**

**Thermostatic radiator valves (TRV).** [Certain] The emitter between tank and room is throttled, not a fixed 312 W/K: `h_trv = clamp(H_rad*(T_trv_set - T_room), 3.12, 312)`, fully open at ≤20 °C, shut at 21 °C (residents' valves sit at position 2-3). This is what lets the tank actually hold charge instead of self-discharging as fast as it fills, and it's the mechanism that makes the tank a store rather than just a hydraulic decoupler. Lives in `getAdaptivePlant.m`; mirrored in the Simulink HP subsystem as a Gain/Saturation pair.

**Heat-pump physics.** [Certain] Real **IDM AERO ALM 4-12** modelled from the verified EN14511 datasheet: `Pth = Pth_min + u·(Pth_max − Pth_min)` above a 5 % modulation gate (`U_OFF`), zero below. Capacity and COP interpolated over outdoor × supply temp. Datasheet NaN holes are **filled by holding the highest achievable flow temperature**, and the operating envelope is queryable.

**Heating limit (Heizgrenze).** [Certain] Hard gate at **15 °C** outdoor — the real heat pump is forced off above it regardless of MPC command, in `hp_heater_physics.m` (the function the actual plant calls). Value taken directly from the hydraulic scheme: *"Die Heizgrenztemperatur ist dabei immer 15 °C."* `heating_curve.m` is the single source of truth. **As of 2026-08-19, `getAdaptivePlant.m` (the MPC's own internal prediction model) also respects this gate** for the CURRENT control step -- previously it did not, so the controller believed it always had compressor capacity even when the real machine was hard off. See §5 item 1 for why this fix, while correct, did not turn out to be sufficient on its own.

**Controller.** [Certain] **Adaptive MPC**, 2-state internal model (`x = [T_room; T_tank]`), horizon p = 96 (24 h), control horizon m = 96 (no move blocking), Ts = 900 s. Re-linearises `A/B/C/D` every control step from the current `T_air_C` and `T_room_C` (the live "MPC Prediction Model" Stateflow chart calls `getAdaptivePlantMats`). Nominal point is the origin (the plant equations have no affine term -- `[20;40]` was tried and is wrong, see the comment block in `getAdaptivePlant.m`). Room bounds `[19, 23] °C` (both soft, `MinECR=0.01`/`MaxECR=0.01`), tank bounds `[25, 55] °C` (`MinECR=0.05`/`MaxECR=1`, tightened 2026-08-19 -- see §5). Weights: `OV = [0.3, 0.1]` (room anchored near 20.2 °C, tank now also given a small constant pull towards 45 °C -- see §5 item 1 for why this was necessary), `MVRate = 0.1`, `MV ∈ [0, 1]`.

**Price in the objective.** [Certain] The MV (compressor command) weight is time-varying: `w(k) = PRICE_WEIGHT * price_kWh(k)/mean(price_kWh)`, fed as a full `[nSamples x p]` preview matrix so the controller sees a real 24 h price forecast at every step, not just the current price. `PRICE_WEIGHT = 0.2`. This is a quadratic cost surrogate, not the true linear energy cost (the MPC Toolbox objective is purely quadratic) -- see §5 item 1 for how well it actually performs.

**Configurable simulation window.** [Certain] `startDate` and `simulationDays` in `init_adaptive_mpc.m` slice both weather and price series to any period of 2025, aligned by real timestamp (handles the DST transition correctly). Default is now a short 2-day window for fast iteration -- see §5 item 1 for the three regimes tested there.

**Analysis & plotting.** [Certain] `analyze_run.m` produces three linked panels (temperatures / HP command / price) with the x-axis auto-scaled to **hours or days**, plus a `results.txt`/`.mat` with cycle count, comfort-bound violations, tank stats, and cost-vs-market comparison, written to `RESULTS/run_<timestamp>/`.

**Data.** [Certain] Real Langenhagen weather (15-min, full year) and real Tibber 2025 prices (15-min, EUR/kWh). `analyze_run` computes **exact per-interval cost** from `price_ts`; the in-model `cost` scalar is the mean, retained only so the Cost Gain block resolves.

---

## 5. Architecture & known issues

1. **Load-shifting does not reliably beat the market mean, and the reason is now well understood.** ⚠ [Certain] **THE CENTRAL FINDING OF THE 2026-08-19 SESSION.** Three genuine bugs were found and fixed first (below), then the controller was short-run tested (1-2 day windows, per the fast-iteration workflow -- see §3) across three distinct weather regimes to characterise where the price mechanism actually lands:

   | Window | Regime | Comfort | Cost vs market |
   |---|---|---|---|
   | 2025-03-15, 2d | Deep cold, compressor on 99% of the time | **Perfect** (0 h below bound) | **+0.8%** (best result) |
   | 2025-03-20, 2d | Shoulder, but crosses the 15°C Heizgrenze ~6h/afternoon | Room to 16.6°C, 13h below bound | +8-9% |
   | 2025-11-01, 2d | Mild, always below Heizgrenze, load ~3kW near the 4kW modulation floor | Room to 18.1°C, 5.25h below bound | +3.4% |

   No configuration tested went *below* market. Each regime hits a different, well-evidenced physical ceiling:
   - **Deep cold:** the compressor must run almost continuously just to meet load (`on_fraction=99%`), leaving almost no slack to time *when* it runs.
   - **Shoulder with a daily Heizgrenze cutoff:** see the detailed root-cause below -- this is the worst case and the one with headroom to actually fix.
   - **Mild, near the modulation floor:** dominated by item 2 below (HP minimum-modulation limit cycling), not by the price mechanism.

   **Root cause of the shoulder-season case, traced directly (not inferred):** the Adaptive MPC block re-linearises `A/B/C/D` every control step from the CURRENT operating point, then holds that single model fixed across the entire 24 h (`p=96`) prediction horizon -- this is how the MATLAB Adaptive MPC block works, not a bug. `Qmax_W` (compressor capacity, in the `B` matrix) is therefore frozen at whatever it is *right now* for the whole horizon. When `T_air_C` is rising towards the 15°C Heizgrenze, the controller's horizon correctly shows *falling room heat loss* (via the always-correctly-previewed weather disturbance) but has **no way to represent that its own compressor capacity is about to hit zero** -- Qmax_W isn't a function of the previewed disturbance trajectory anywhere in this architecture. A traced 2-day run showed the direct consequence: at a point where room was fine (20.0°C), price was cheap (0.221 EUR/kWh, near the cheapest in the run), and the Heizgrenze gate was still open, the controller voluntarily commanded `u=0` -- a full hour *before* the gate even closed -- and then stayed at `u=0` for a continuous 8 h, only reacting the instant the gate reopened. It reads "outdoor temp rising" as "less heating needed soon", never as "capacity is about to vanish".

   **Fixes tried and their actual effect** (all short-run tested against the 2025-03-20 window before/after):
   1. `Qmax_W` corrected to respect the Heizgrenze gate at the CURRENT step (`getAdaptivePlant.m`) -- **kept**, it's a real model/plant mismatch fix, but changed the room-min/hours-below numbers by less than 0.1°C/0.5h on its own.
   2. Tank `MinECR` tightened `1 → 0.05` -- **kept** (parallels the room's own `MinECR=0.01`; the tank is the room's only heat source so its floor shouldn't be ~20x softer than the room's), but bit-for-bit identical result combined with fix 1 alone.
   3. Room `OV(1)` weight raised `0.2 → 0.5` -- **reverted**, no change to the crash at all (the room wasn't the free variable; its only supply, the tank, was).
   4. MV-weight discount timed before a predicted cutoff, at two strengths (0.3x and a much more aggressive 0.03x) -- **reverted, does not work, do not re-add** without also fixing the root cause. Both landed within noise of no discount at all, and the aggressive setting made the QP so poorly conditioned it took ~30 minutes to solve a 2-day run instead of under a minute, for zero behavioural benefit. Discounting *cost* cannot fix a wrong *belief* about capacity.
   5. Tank `OV(2)` given a small constant weight (`0.1`, pulling towards `T_tank_ref=45`) instead of `0` -- **kept, the only fix that measurably helped**: hours below the comfort floor dropped from 15.5-17.8h to 13.0h over the same window, tank average level rose from ~28°C to ~31°C. Does not fully close the gap (room still touches ~16.6°C at the deepest point of the longest cutoff), but it's real.

   **What would actually close the remaining gap** (follow-up work, not a tuning question): either (a) a genuinely time-varying / gain-scheduled prediction model that schedules `Qmax_W` across the horizon from the previewed `T_air_C` trajectory instead of freezing it at step 0 -- a real MPC redesign, not available as a simple Adaptive MPC block option; or (b) exposing time-varying OV bounds on the Simulink block so the tank's minimum can be raised specifically ahead of a known cutoff. The auto-generated MPC block's mask does not currently expose time-varying constraints as an inport for this option; wiring it in is genuine Simulink structural surgery, not an `init_adaptive_mpc.m` change.

2. **HP minimum-modulation floor → limit cycling.** [Certain] The ALM 4-12 cannot deliver below ~4 kW. Loads that sit near that floor (the 2025-11-01 shoulder test above: ~3 kW) force the machine to pulse on/off rather than modulate smoothly -- **67.5 cycles/day, 13 min average run length, 66% of intervals below-floor** in that test. **An actuator limit, not a model or tuning problem.** The buffer tank meaningfully reduces this versus no tank at all (§6), but does not eliminate it when the load itself sits at the floor.

3. **`HP Physics` takes `T_supply_C` from the heating curve, not the tank.** [Certain] With a buffer, condenser temperature is a **state**, not a weather function. COP is currently evaluated at the wrong temperature. The heating curve's role would need to change from "actual supply temp" to "tank charging setpoint" to fix this. **Still open.**

4. **The heating curve is linear; real radiator curves are not.** [Certain] `heating_curve.m` interpolates linearly −10/55 → 15/35. Radiators follow an exponent law (EN 442, n ≈ 1.3). At half load the linear form gives **44.6 °C vs 40.1 °C** correct — ~4–5 K too hot through the entire mid-season, where most heating hours sit. Effect: COP underestimated ~0.2, **electricity cost systematically overestimated ~5–7 %**, i.e. biased against the thing being optimised. **Still open.**

5. **Modulation mapping has an offset bug.** [Certain] `Pth = Pth_min + u·(Pth_max − Pth_min)` gives ≈ 4.4 kW at `u = U_OFF = 0.05`, not `Pth_min` = 4.0 kW. Needs renormalising to `u_eff = (u − U_OFF)/(1 − U_OFF)`. Minor; the linear Pel-vs-Pth interpolation itself is correct and matches EN 14825. **Still open.**

6. **6 kW Heizstab not modelled.** [Certain] The as-built scheme shows an `Inneneinheit 6 kW Heizstab`. Only relevant below ~−5 °C, where the HP (8.67 kW at −15 °C) cannot meet the ~11 kW load. Runs at **COP 1** — roughly double the cost per kWh of heat versus the HP at cold conditions, so it matters for winter cost figures. **Decision pending:** plant-side rule (keeps one MV) vs. second MPC decision variable.

7. **T_supply is not an MPC decision.** [Certain] Making it a true second MV exposes a **bilinear plant** (`Qmax = f(T_air, T_supply)`), forcing a choice between `nlmpc` and gain-scheduling. **Unresolved.**

8. **Suspected plant/controller capacity mismatch.** ⚠ [Likely] The pre-tank July sawtooth (~2000 s period, ~7 K swing) implies an effective air-node capacity of order 5e5 J/K in the Simscape plant, versus **C = 7.46e7 J/K** in the MPC model — roughly 100× apart. If real, the controller predicts a sluggish room and gets a twitchy one. **Not yet verified against the plant's thermal-mass block.**

9. **`fix_mpc_codegen.m` is a landmine.** [Certain] Its baked-in `plantBody()` still holds **old example params** and a hardcoded `T_supply_C = 50`. Running it **reverts the plant to the demo building**. Must be updated or retired. **Never run as-is.**

10. **Simulink `SimulationMode` can silently break every run on a machine with no C compiler.** ⚠ [Certain] **NEW, 2026-08-19.** `apply_performance_settings.m` used to set `SimulationMode='accelerator'` unconditionally and **save** it into the .slx. On a machine without `mex -setup C` configured, `sim()` then fails immediately with "No supported compiler detected" -- and because the mode is saved, every subsequent session fails the same way until someone notices. This is almost certainly why several runs on 2026-08-17 produced an empty `console.log` and no `results.txt`. **Fixed:** the script now checks `mex.getCompilerConfigurations('C','Selected')` first and falls back to `'normal'` with a warning if none is found. The model has been re-saved with `SimulationMode='normal'`.

11. **The MPC's internal model didn't know about the Heizgrenze gate.** [Certain] **NEW, 2026-08-19, see item 1 above for the full story.** `getAdaptivePlant.m` computed `Qmax_W` via `hp_capacity_lookup` directly, which has no Heizgrenze check -- only `hp_heater_physics.m` (the function the real plant calls) had the gate. Fixed for the current control step; item 1 explains why this alone wasn't sufficient.

### ✅ Resolved since last update (2026-08-09 → 2026-08-19)

- **2-state (room + tank) controller model.** The MPC's internal model now has `x=[T_room;T_tank]`, not 1R1C — it knows the tank exists and predicts through it.
- **TRV / emitter throttling modelled.** The tank can now actually hold charge instead of self-discharging as fast as it fills (§4).
- **Price wired into the MPC objective.** Time-varying MV weight from real Tibber prices, previewed a full 24 h ahead (§4).
- **Nominal operating point fixed to the origin.** The old `[20;40]` anchor asserted a 40°C tank holds steady with the pump off; it actually falls ~10.7 K/h at that point. This was a major contributor to excess cycling.
- **`SimulationMode` compiler landmine.** See item 10 above.
- **MPC-internal Heizgrenze blindness.** See item 11 above.
- **30,162 W silent resistive fallback — removed.** Both `hp_capacity_lookup.m` and `hp_heater_physics.m` previously substituted a fictitious 30 kW COP-1 heater off-envelope (~3× the design load). Replaced with NaN-filled grids, a one-shot envelope warning, and a hard error on genuine NaN.
- **No heating limit / no upper comfort bound / hardcoded simulation window / unreadable plot axes.** All fixed, see §4.

---

## 6. Results so far

**Example building (stock demo, τ ≈ 1.7 h).** [Certain] Room chattered around 20 °C everywhere, dipping to ~15 °C in cold spells — the air-only mass couldn't integrate on/off pulses.

**Real building, no tank (τ ≈ 57 h).** [Certain] Room tracks 20 °C **smoothly through cold weather** (demand 6–8 kW, inside the modulating band). Cycling survives only in mild windows (outdoor ≳ 9 °C) plus a startup transient. Correct behaviour: residual cycling is the HP floor, not the math.

**July stress test, no tank.** [Certain] With the Heizgrenze tested at instantaneous 16 °C, a 10-day July window produced **severe limit cycling (18–28 °C)** clustered on cold nights in the second half of the run. Two causes: an instantaneous gate opens on any cold night, and the 4 kW floor is ~2× the July load. **This is the clearest available demonstration of why the buffer is needed** — worth retaining as a thesis figure before the Heizgrenze is refined to a sliding daily mean.

**Real building with tank + TRV + price-weighted 2-state MPC (2026-08-19 short-run tests).** [Certain] See §5 item 1 for the full three-regime table and root-cause analysis. Summary: comfort is now solid in cold and mild-but-gated-off conditions (0 h and 5.25 h below bound respectively), and meaningfully improved (down from 15.5-17.8h to 13.0h) in the worst shoulder-season case. Cost consistently lands close to but *above* the market mean (+0.8% best case, +3.4% to +9% depending on regime) — **the load-shifting objective is implemented, runs, and is well-characterised, but does not yet demonstrate a below-market result.** This is now a well-evidenced finding with a clear causal story (§5 item 1), not an open question.

**Where that leaves us.** [Certain] Plant, comfort, TRV, buffer, 2-state model and price objective are all implemented and validated against real short runs. **The cost-optimisation objective is implemented and exercised, but its central claim — paying less than the market mean by shifting load — is not yet demonstrated.** The gap has a specific, traced root cause (§5 item 1) and two credible follow-up paths, rather than being an open unknown.

---

## 7. Companion Python / RL track (from project records)

*(Summarised from the project log; files not re-read for this document.)*

- **SAC single-building result: locked.** [Likely] Comfort competitive with a rule-based baseline; price-responsiveness demonstrated. A complete, defensible thesis result on its own.
- **Multi-building generalisation (TABULA fleet): characterised failure.** [Likely] Persistent over/under-heating from reward asymmetry and policy collapse (near-constant output regardless of room state). Either fix, or document as a result.
- **Python MPC baseline: exists, comparison not yet valid.** [Likely] Disturbance-scaling asymmetry between MPC and the gym env; `--grid_on` defaults False, so price-aware optimisation was not active in completed runs.
- Stack: 4R3C/3R2C thermal model, CVXPY/CLARABEL, Stable-Baselines3 SAC. Key lesson: pair `best_model.zip` with the **matching** `vecnormalize_{N}_steps.pkl`.

---

## 8. What still needs to be implemented (prioritised)

**MATLAB track — core contribution, highest priority**
1. **Close the Heizgrenze-foresight gap (§5 item 1).** Either (a) a genuinely time-varying/gain-scheduled prediction model that schedules `Qmax_W` across the horizon instead of freezing it at step 0, or (b) exposing time-varying OV bounds on the Simulink block so the tank's minimum can be raised ahead of a known cutoff. This is the single biggest lever left on the actual research claim (paying below market). Do NOT re-attempt an MV-weight-discount approach without a different mechanism — it was tried at two strengths and traced to not work (§5 item 1, fix 4).
2. **Re-run the three-regime short tests (§5 item 1) after whichever fix from (1) is implemented**, plus a genuine multi-day run once a config looks promising, to confirm the below-market result generalises rather than being a single-window artifact.

**MATLAB track — correctness**
3. Rewire `HP Physics` `T_supply_C` ← `Ttank` so COP is evaluated at the real condenser temperature, not the weather-driven heating curve (§5 item 3).
4. Fix the heating curve to exponent form and parameterise slope/offset (§5 item 4).
5. Fix the modulation offset at `u = U_OFF` (§5 item 5).
6. Decide Heizstab treatment — plant-side rule vs. second MV (§5 item 6).
7. Verify the plant's air thermal mass against the MPC's `C_air` (§5 item 8).
8. Confirm θe → lock UA (§2).
9. Consider a sliding-daily-mean Heizgrenze instead of instantaneous.
10. Update or retire `fix_mpc_codegen.m` (§5 item 9).
11. Execute the file cleanup/archiving pass (§3).

**Python track**
12. Re-run MPC-vs-SAC with `--grid_on` active and consistent disturbance scaling.
13. Fix multi-building RL generalisation, or finalise it as a documented failure mode.

---

## 9. Are we where we want to be?

**Closer, and now honestly characterised rather than just "not yet implemented."**

- **Infrastructure: done.** [Certain] Real building, real HP physics, real weather, real prices, working Adaptive-MPC loop, realistic multi-timescale plant, buffer tank with working TRV throttling, 2-state controller model, price-weighted objective.
- **Correctness pass: substantial, and two more real bugs found and fixed this session.** [Certain] The silent 30 kW fallback is gone, the heating limit matches the as-built documentation, comfort bounds are enforced, `SimulationMode` no longer silently breaks every run on a machine without a compiler, and the MPC's internal model now respects the Heizgrenze gate at the current step.
- **The thesis contribution — cost-aware load-shifting — is implemented and runs, but does not yet demonstrate paying below the market mean.** [Certain] This is the honest, current bottom line. Best result found: 0.8% *above* market with perfect comfort, in a deep-cold window where the compressor runs almost continuously anyway. The gap is not a mystery: §5 item 1 traces it to a specific, structural limitation (the adaptive MPC cannot foresee the Heizgrenze cutoff within its own frozen-per-step prediction horizon) and rules out five tuning-only fixes with short-run evidence, not guesswork. The Python/SAC side *has* shown price-responsiveness single-building, so the concept is proven on one track; it is not yet proven on this one.

**One-line status:** the simulator is real, documented, and trustworthy; the controller genuinely tries to minimise cost subject to comfort, but a structural blind spot in the Adaptive MPC architecture (not a weight-tuning problem) is what's standing between "close to market" and "below market." §5 item 1 / §8 item 1 is the next real piece of work.

---

## 10. Immediate next steps

1. Decide between the two Heizgrenze-foresight fixes in §8 item 1 (time-varying prediction model vs. time-varying OV bounds) and implement one.
2. Re-run the three-regime short tests (§5 item 1) against that fix; confirm at least one regime goes genuinely below market.
3. Validate with a longer (multi-day, spanning both cheap and expensive periods) run once a config looks promising — short runs are for iteration, not the final claim.
4. Then work the correctness list in §8 (T_supply/Ttank coupling, heating curve exponent form, modulation offset, Heizstab).
