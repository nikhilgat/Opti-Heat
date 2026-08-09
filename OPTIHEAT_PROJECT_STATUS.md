# OPTIHEAT — Project Status & Implementation Log

> Price-responsive heat-pump control for a real multi-family building.
> Master's thesis · BMWK 8th Energy Research Programme.
> Last updated: 2026-08-09.

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
  init_adaptive_mpc.m        Build mpcobj + plant_d0, load+slice weather/price, set StopTime. RUN FIRST.
  run_adaptive_mpc_hp.m      Body of the Adaptive-MPC 'model' inport (per-step linear plant).
  analyze_run.m              Runs sim, counts compressor starts, computes kWh + real cost, plots.
HEATPUMP/
  idm_alm412_datasheet.m     Raw EN14511 performance tables (W35–W70, −20…+20 °C).
  idm_alm412_interpolants.m  Pth max/min + COP interpolants; NaN-filled grids + envelope query.
  hp_capacity_lookup.m       Scalar Pth [W] lookup; envelope warn, error on NaN.
  hp_heater_physics.m        Heizgrenze gate + modulation → Heat_W, Elec_W.
  heating_curve.m            Outdoor temp → supply temp + heating-limit flag.
SIM-MODEL/
  HouseHeatingSystem.slx     Main model: Adaptive MPC + HP subsystem (incl. buffer tank) + Simscape House.
  getAdaptivePlant.m         Linear 1R1C plant as ss/c2d object (interpreted path).
  getAdaptivePlantMats.m     Same as raw A,B,C,D matrices (codegen path).
  patch_plant_to_virchowstr6.m   One-time retarget of Simscape plant (already applied).
DATA/
  weather_langenhagen_2025.csv       15-min outdoor temp, full year (Open-Meteo). Cols: timestamp, T_out_C.
  electricity_prices_2025.csv        Tibber 2025, 15-min, EUR/kWh, German decimals.
BUFFER_TANK.md               Buffer-tank integration reference.
OPTIHEAT_PROJECT_STATUS.md   This file.
```

**Flagged for deletion / archiving** (identified, not yet executed): `Basic-Heater/` (superseded), `characterize_example_building.m`, `virchowstrBuildingParameters.m` (orphaned), `fix_mpc_codegen.m` (see §5), `HouseHeatingSystem.slxc` + `slprj/` (build cache), duplicate `.drawio`.

**Run order:** `addpath(genpath(pwd))` → `init_adaptive_mpc` → `analyze_run`.

---

## 4. What is implemented

**Plant (the simulated house).** [Certain] A Simscape **4-mass thermal network** (air + wall + roof + window nodes) — the stock MathWorks demo, **retargeted to Virchowstr. 6** with real geometry / U-values / masses and a **ventilation leg** (153 W/K). Total plant UA ≈ 366 W/K, C = 7.46e7 J/K, τ ≈ 57 h.

**Buffer tank.** ✅ [Certain] **NEW.** 500 L Kermi buffer now modelled inside the HP subsystem as a Simscape `Thermal Mass` (C = 2.093e6 J/K), with an `Emitter` conductance (312 W/K) to the room, a `Tank Loss` leg (1.9 W/K) to a 15 °C plant room, and an absolute `Temperature Sensor` exporting `Ttank`. The heat pump now charges water rather than heating room air directly. **Full detail in `BUFFER_TANK.md`.**

**Heat-pump physics.** [Certain] Real **IDM AERO ALM 4-12** modelled from the verified EN14511 datasheet: `Pth = Pth_min + u·(Pth_max − Pth_min)` above a 5 % modulation gate (`U_OFF`), zero below. Capacity and COP interpolated over outdoor × supply temp. Datasheet NaN holes are now **filled by holding the highest achievable flow temperature**, and the operating envelope is queryable.

**Heating limit (Heizgrenze).** ✅ [Certain] **NEW.** Hard gate at **15 °C** outdoor — the heat pump is forced off above it regardless of MPC command. Value taken directly from the hydraulic scheme: *"Die Heizgrenztemperatur ist dabei immer 15 °C."* `heating_curve.m` is the single source of truth; `hp_heater_physics.m` reads the flag from it.

**Controller.** [Certain] **Adaptive MPC**, horizon p = 48 (12 h), control horizon m = 5, Ts = 900 s. Internal model still a **reduced 1R1C** rebuilt each step. Weights: OV = 1.0, MVRate = 0.1, MV ∈ [0, 1]. Room bounds now constrained: **`OV.Min = 19` (soft), `OV.Max = 24` (hard, `MaxECR = 0`)**. Still **purely setpoint-tracking** — no price term.

**Configurable simulation window.** ✅ [Certain] **NEW.** `startDate` and `simulationDays` in `init_adaptive_mpc.m` slice both weather and price series to any period of 2025. Price index is computed independently from 2025-01-01 so the two stay calendar-aligned.

**Analysis & plotting.** ✅ [Certain] **NEW.** `analyze_run.m` produces three linked panels (temperatures / HP command / price) with the x-axis auto-scaled to **hours or days** and the y-axis in **°C**. Logging is guarded so Simscape physical lines can't abort the run.

**Data.** [Certain] Real Langenhagen weather (15-min, full year) and real Tibber 2025 prices (15-min, EUR/kWh). `analyze_run` computes **exact per-interval cost** from `price_ts`; the in-model `cost` scalar is the mean, retained only so the Cost Gain block resolves.

---

## 5. Architecture & known issues

1. **HP minimum-modulation floor → limit cycling.** [Certain] The ALM 4-12 cannot deliver below ~4 kW. Below ~9 °C outdoor demand the pump **must cycle** — an **actuator limit, not model mismatch**. A July run without the tank showed the room sawtoothing **18–28 °C** with ~2000 s period. **The buffer tank now absorbs this** (§4), which was its primary justification.

2. **The tank cannot yet hold charge.** ⚠ [Certain] **NEW.** The Emitter is an unconditional conductance — heat flows whenever `T_tank > T_room`, with no pump or mixer gate (the real system has M31.1/M31.2 and mixer M41). The tank therefore **self-discharges as fast as it charges**, parking ~13 K above room temperature. Delivers **cycle reduction but almost no load-shifting**. Adding a pump gate is the next increment.

3. **MPC internal model still 1R1C — it does not know the tank exists.** ⚠ [Certain] **NEW.** The controller predicts as though it heats room air directly. Control quality will be poor until upgraded to a 2-state (room + tank) model. A `Mux` of `[Troom; Ttank]` into the `mo` port is prepared but **must not be connected** until `mpcobj` is 2-output — it throws a port-width error.

4. **`HP Physics` takes `T_supply_C` from the heating curve, not the tank.** ⚠ [Certain] With a buffer, condenser temperature is a **state**, not a weather function. COP is currently evaluated at the wrong temperature. The heating curve's role must change from "actual supply temp" to "tank charging setpoint".

5. **The heating curve is linear; real radiator curves are not.** ⚠ [Certain] **NEW.** `heating_curve.m` interpolates linearly −10/55 → 15/35. Radiators follow an exponent law (EN 442, n ≈ 1.3). At half load the linear form gives **44.6 °C vs 40.1 °C** correct — ~4–5 K too hot through the entire mid-season, where most heating hours sit. Effect: COP underestimated ~0.2, **electricity cost systematically overestimated ~5–7 %**, i.e. biased against the thing being optimised. Also only one curve is implemented; a slope/offset-parameterised family would enable curve-tuning as a baseline.

6. **Modulation mapping has an offset bug.** ⚠ [Certain] **NEW.** `Pth = Pth_min + u·(Pth_max − Pth_min)` gives ≈ 4.4 kW at `u = U_OFF = 0.05`, not `Pth_min` = 4.0 kW. Needs renormalising to `u_eff = (u − U_OFF)/(1 − U_OFF)`. Minor; the linear Pel-vs-Pth interpolation itself is correct and matches EN 14825.

7. **6 kW Heizstab not modelled.** ⚠ [Certain] **NEW.** The as-built scheme shows an `Inneneinheit 6 kW Heizstab`. Only relevant below ~−5 °C, where the HP (8.67 kW at −15 °C) cannot meet the ~11 kW load. Runs at **COP 1** — roughly double the cost per kWh of heat versus the HP at cold conditions, so it matters for winter cost figures. **Decision pending:** plant-side rule (keeps one MV) vs. second MPC decision variable.

8. **Price signal not in the objective.** ⚠ [Certain] The MPC only tracks setpoint. Prices are loaded, sliced, and used for **post-hoc cost accounting** in `analyze_run`, but never enter the cost function. **The headline research feature (load-shifting) is still not active.**

9. **T_supply is not an MPC decision.** [Certain] Making it a true second MV exposes a **bilinear plant** (`Qmax = f(T_air, T_supply)`), forcing a choice between `nlmpc` and gain-scheduling. **Unresolved.**

10. **Suspected plant/controller capacity mismatch.** ⚠ [Likely] **NEW.** The pre-tank July sawtooth (~2000 s period, ~7 K swing) implies an effective air-node capacity of order 5e5 J/K in the Simscape plant, versus **C = 7.46e7 J/K** in the MPC model — roughly 100× apart. If real, the controller predicts a sluggish room and gets a twitchy one. **Not yet verified against the plant's thermal-mass block.**

11. **`fix_mpc_codegen.m` is a landmine.** ⚠ [Certain] Its baked-in `plantBody()` still holds **old example params** and a hardcoded `T_supply_C = 50`. Running it **reverts the plant to the demo building**. Must be updated or retired. **Never run as-is.**

### ✅ Resolved since last update

- **30,162 W silent resistive fallback — removed.** Both `hp_capacity_lookup.m` and `hp_heater_physics.m` previously substituted a fictitious 30 kW COP-1 heater off-envelope (~3× the design load). The capacity-lookup case was the more dangerous: it fed `getAdaptivePlant`, inflating the MPC's B matrix ~3× and making the controller over-confident. Replaced with NaN-filled grids, a one-shot envelope warning, and a hard error on genuine NaN.
- **No heating limit.** Fixed — see §4.
- **No upper comfort bound.** Fixed — `OV.Max = 24 °C` hard.
- **Hardcoded simulation window.** Fixed — `startDate` selectable.
- **Unreadable plot axes.** Fixed — days/hours + °C.

---

## 6. Results so far

**Example building (stock demo, τ ≈ 1.7 h).** [Certain] Room chattered around 20 °C everywhere, dipping to ~15 °C in cold spells — the air-only mass couldn't integrate on/off pulses.

**Real building, no tank (τ ≈ 57 h).** [Certain] Room tracks 20 °C **smoothly through cold weather** (demand 6–8 kW, inside the modulating band). Cycling survives only in mild windows (outdoor ≳ 9 °C) plus a startup transient. Correct behaviour: residual cycling is the HP floor, not the math.

**July stress test, no tank.** [Certain] With the Heizgrenze tested at instantaneous 16 °C, a 10-day July window produced **severe limit cycling (18–28 °C)** clustered on cold nights in the second half of the run. Two causes: an instantaneous gate opens on any cold night, and the 4 kW floor is ~2× the July load. **This is the clearest available demonstration of why the buffer is needed** — worth retaining as a thesis figure before the Heizgrenze is refined to a sliding daily mean.

**Real building with tank.** [Pending] Smoke test not yet run. See `BUFFER_TANK.md` §7 for the four acceptance checks.

**Where that leaves us.** [Likely] Plant and comfort behaviour validated and realistic; the buffer is now physically represented. **The cost-optimisation objective — the actual thesis contribution — remains unimplemented in the MATLAB track.**

---

## 7. Companion Python / RL track (from project records)

*(Summarised from the project log; files not re-read for this document.)*

- **SAC single-building result: locked.** [Likely] Comfort competitive with a rule-based baseline; price-responsiveness demonstrated. A complete, defensible thesis result on its own.
- **Multi-building generalisation (TABULA fleet): characterised failure.** [Likely] Persistent over/under-heating from reward asymmetry and policy collapse (near-constant output regardless of room state). Either fix, or document as a result.
- **Python MPC baseline: exists, comparison not yet valid.** [Likely] Disturbance-scaling asymmetry between MPC and the gym env; `--grid_on` defaults False, so price-aware optimisation was not active in completed runs.
- Stack: 4R3C/3R2C thermal model, CVXPY/CLARABEL, Stable-Baselines3 SAC. Key lesson: pair `best_model.zip` with the **matching** `vecnormalize_{N}_steps.pkl`.

---

## 8. What still needs to be implemented (prioritised)

**MATLAB track — immediate**
1. **Smoke-test the tank** — 3 days from a mild-season start (e.g. 2025-10-15); verify the four checks in `BUFFER_TANK.md` §7.
2. **Upgrade controller model 1R1C → 2-state (room + tank)** — `getAdaptivePlant`, `init_adaptive_mpc`, `run_adaptive_mpc_hp`; then reconnect the `[Troom; Ttank]` Mux to `mo`.
3. **Rewire `HP Physics` `T_supply_C` ← `Ttank`** so COP is evaluated at the real condenser temperature.
4. **Decide Heizstab treatment** — plant-side rule vs. second MV.

**MATLAB track — core contribution**
5. **Wire price into the MPC objective** — converts setpoint-tracking into cost-minimisation. *Highest research priority.*
6. **Add a pump/mixer gate on the emitter** — without it the tank cannot store, so load-shifting has little to work with.

**MATLAB track — correctness**
7. Fix the heating curve to exponent form and parameterise slope/offset (§5.5).
8. Fix the modulation offset at `u = U_OFF` (§5.6).
9. Verify the plant's air thermal mass against the MPC's `C_air` (§5.10).
10. Confirm θe → lock UA (§2).
11. Consider a sliding-daily-mean Heizgrenze instead of instantaneous.
12. Update or retire `fix_mpc_codegen.m`.
13. Execute the file cleanup/archiving pass (§3).

**Python track**
14. Re-run MPC-vs-SAC with `--grid_on` active and consistent disturbance scaling.
15. Fix multi-building RL generalisation, or finalise it as a documented failure mode.

---

## 9. Are we where we want to be?

**Partly — and honestly so.**

- **Infrastructure: done, and now more complete.** [Certain] Real building, real HP physics, real weather, real prices, working Adaptive-MPC loop, realistic multi-timescale plant, **and the buffer tank that the real installation depends on**.
- **Correctness pass: substantial progress.** [Certain] The silent 30 kW fallback is gone, the heating limit matches the as-built documentation, and comfort bounds are enforced. Several genuine modelling errors were found and either fixed or logged with their magnitude.
- **The thesis contribution — cost-aware load-shifting — is still NOT demonstrated in MATLAB.** [Certain] Price isn't in the objective, the controller model can't yet see the tank, and the tank can't yet hold charge. The Python/SAC side *has* shown price-responsiveness single-building, so the concept is proven on one track.

**One-line status:** the simulator is real, documented, and increasingly trustworthy; the remaining work is turning the controller from "hold 20 °C" into "hold 20 °C for the least money," which now needs the 2-state model, the price term, and a gated emitter.

---

## 10. Immediate next steps

1. Run the tank smoke test and confirm the four checks.
2. Answer the Heizstab question (rule vs. MV).
3. Write the 2-state MPC model and reconnect the `mo` Mux.
4. Rewire condenser temperature to `Ttank`.
5. Wire the price series into the MPC cost function.
