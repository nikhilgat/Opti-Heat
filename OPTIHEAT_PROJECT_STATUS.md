# OPTIHEAT — Project Status & Implementation Log

> Price-responsive heat-pump control for a real multi-family building.
> Master's thesis · BMWK 8th Energy Research Programme.
> Last updated: 2026-07-09.

**Confidence legend** (used throughout): `[Certain]` = documented / hard evidence · `[Likely]` = strong inference · `[Guess]` = filling a gap, treat as a knob.

---

## 1. What this project is

Develop and compare **cost-minimising control strategies for an air-source heat pump** heating a real 5-unit residential building, using ENTSO-E day-ahead electricity prices, while holding thermal comfort. Two parallel workstreams:

1. **MATLAB / Simulink** — an **Adaptive MPC** controller driving a Simscape thermal-network plant, with real IDM heat-pump physics. *(This repo — `C:\Users\nikhi\Documents\MATLAB\MPC`.)*
2. **Python / i4b** — **Reinforcement Learning (SAC)** and a Python **MPC** baseline in a gym environment. *(Companion repos `i4b` / `i4b_reinforcement_learning` — summarised in §7 from project records, not re-read for this doc.)*

The end goal for both: replace pure setpoint-tracking with a controller that **shifts heat-pump load into cheap-price hours** using the building's thermal mass, without losing comfort.

---

## 2. The building — Virchowstr. 6, 30853 Langenhagen

1963 solid-brick multi-family house, 5 apartments, renovated 2025 (KfW152: façade + roof insulation + heat pump), windows replaced 2020. No gas/boiler fallback.

| Parameter | Value | Source | Conf. |
|---|---|---|---|
| Heated floor area | 287.92 m² | Vonovia balancing sheet | [Certain] |
| **Design heat load** | **10,968 W** | Vonovia balancing sheet | [Certain] |
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

### ⚠ Open calibration point — UA is ~6 % high

UA = 366 assumes design outdoor temp **θe = −10 °C**, which is the one number **not yet confirmed from the documents** (the Norm-Außentemperatur printed on the Vonovia sheet hasn't been located in OCR). Two independent cross-checks point lower:

- Envelope estimate `H_tr + H_ve ≈ 282–343 W/K` → consistent with θe ≈ −12 °C. [Likely]
- **Annual-energy check:** UA 345 W/K × Hannover degree-hours (~3700 K·d) ≈ 30,600 kWh/a, landing on the documented 30,874 within ~1 %. [Likely]

→ **True UA is likely ≈ 345 W/K (θe ≈ −12 °C)**, not 366. Refinement pending; see §8.

---

## 3. Repository map (`MATLAB/MPC`)

```
A-MPC/
  init_adaptive_mpc.m        Build mpcobj + plant_d0, load weather, set StopTime. RUN FIRST.
  run_adaptive_mpc_hp.m      Body of the Adaptive-MPC 'model' inport (per-step linear plant).
  fix_mpc_codegen.m          Wraps block scripts in coder.extrinsic. ⚠ HOLDS STALE PARAMS (§5).
Basic-Heater/
  BasicHeater_HouseHeatingSystem.slx   Stock MathWorks baseline (pre-HP).
  BasicHeater_HouseHeatingSystemExample.m
HEATPUMP/
  idm_alm412_datasheet.m     Raw EN14511 performance tables (W35–W70, −20…+20 °C).
  idm_alm412_interpolants.m  Pth max/min + COP interpolants; min-modulation floor + U_OFF gate.
  hp_capacity_lookup.m       Scalar Pth [W] lookup; ⚠ 30,162 W resistive fallback off-envelope.
  hp_heater_physics.m        On/off + modulation → Heat_W, Elec_W.
  heating_curve.m            Outdoor temp → supply temp (weather compensation).
SIM-MODEL/
  HouseHeatingSystem.slx     Main model: Adaptive MPC + Heater(HP) + Simscape House + scopes.
  getAdaptivePlant.m         Linear 1R1C plant as ss/c2d object (interpreted path).
  getAdaptivePlantMats.m     Same as raw A,B,C,D matrices (codegen path).
  patch_plant_to_virchowstr6.m   Retargets Simscape plant to the real building + adds ventilation.
  virchowstrBuildingParameters.m Standalone real-building param set (Req, C_air, Ts).
characterize_example_building.m   Reports the stock demo's thermal identity (for comparison).
DATA/
  weather_langenhagen_2025.csv       15-min outdoor temp, ~full year (Open-Meteo).
  electricity_prices_2025.csv        ENTSO-E DE_LU day-ahead. ⚠ LOADED BUT NOT WIRED (§5).
```

---

## 4. What is implemented

**Plant (the simulated house).** [Certain] A Simscape **4-mass thermal network** (air + wall + roof + window nodes) — the stock MathWorks *House Heating System* demo, now **retargeted to Virchowstr. 6** by `patch_plant_to_virchowstr6.m`, which rewrites the model InitFcn to the real geometry / U-values / masses (bulk of the mass in the brick walls) and **adds a ventilation leg** (153 W/K, air↔atmosphere) the demo lacked. Total plant UA ≈ 366 W/K, C = 7.46e7 J/K, τ ≈ 57 h.

**Heat-pump physics.** [Certain] Real **IDM AERO ALM 4-12** (4–12 kW inverter ASHP) modelled from the verified EN14511 datasheet: `Pth = Pth_min + u·(Pth_max − Pth_min)` above a 5 % modulation gate (`U_OFF`), zero below. Capacity and COP interpolated over outdoor temp × supply temp. Weather-compensated supply temp from `heating_curve.m`.

**Controller.** [Certain] **Adaptive MPC** (`mpc` object), horizon p = 48 (12 h), control horizon m = 5, Ts = 900 s. Internal model is a **reduced 1R1C** (`Req = 1/366`, `C_air = 7.46e7`) rebuilt each step by `getAdaptivePlant`/`Mats` from current outdoor + supply temp. Weights: OV = 1.0, MVRate = 0.1, MV ∈ [0, 1]. **Purely setpoint-tracking** (holds 20 °C).

**Data.** [Certain] Real Langenhagen weather (15-min, ~1 yr) drives outdoor temp; run length auto-matches the weather span (`init` sets StopTime). ENTSO-E prices present as a CSV and a flat placeholder `cost` scalar.

**Support tooling.** Building characterisation script, plant-retarget patch, standalone param file, codegen fixer.

---

## 5. Architecture & known issues

1. **HP minimum-modulation floor → limit cycling (fundamental).** [Certain] The ALM 4-12 cannot deliver below ~4 kW; below threshold it's off. When building demand drops under ~4 kW (mild weather, outdoor ≳ 9 °C), the pump **must cycle on/off** to average down. This is an **actuator limit, not model mismatch** — no controller can remove it. The real building's **500 L Kermi buffer tank** absorbs this; **the simulation has no buffer**, so the cycling shows directly in room temperature. [Likely]

2. **`fix_mpc_codegen.m` is a landmine.** ⚠ [Certain] It rewrites the embedded MATLAB-Function-block scripts, and its baked-in `plantBody()` still contains the **old example params** (windowArea = 6, wallArea = 320, M_air = 1496) **and a hardcoded `T_supply_C = 50`**. Running it **reverts the plant model to the demo building** and overrides the heating curve. Must be updated to the real params before it is ever run again.

3. **T_supply is not an MPC decision.** [Certain] It's set by the heating curve (open-loop weather compensation). Making it a true second manipulated variable exposes a **bilinear plant** (`Qmax = f(T_air, T_supply)`), which forces a choice between `nlmpc` (nonlinear) and gain-scheduling. **Unresolved.**

4. **Price signal not in the objective.** ⚠ [Certain] The MPC only tracks setpoint. `electricity_prices_2025.csv` is loaded but never enters the cost function; `cost` is a flat scalar. **The headline research feature (load-shifting) is not active yet.**

5. **Silent resistive fallback.** [Certain] `hp_capacity_lookup` returns **30,162 W** if (T_air, T_supply) leaves the datasheet envelope — the "heat pump" briefly becomes a 30 kW resistive element. Can mask envelope-edge behaviour; worth a guard/log.

6. **1R1C controller model vs 4-mass plant.** [Likely] Intentional (reduced controller model, richer plant) and fine for tracking — but 1R1C cannot represent the fast-air / slow-wall split that load-shifting exploits. A **2R2C** controller model is the recommended upgrade before trusting cost-optimisation results.

7. **HP marginally undersized at design.** [Likely] Datasheet max heat at −10 °C is ≈ 9.7–9.85 kW (W55/W35) vs the 10.97 kW design load — the pump can't fully cover the −10 °C design condition alone. Real-world relevance only; not a bug.

---

## 6. Results so far

**Example building (stock demo, τ ≈ 1.7 h).** [Certain] Room chattered around 20 °C **everywhere**, with deep dips to ~15 °C in cold spells — the tiny air-only mass couldn't integrate the on/off pulses, and the linear MPC fought the discontinuous heater.

**Real building (retargeted plant, τ ≈ 57 h).** [Certain] Room tracks 20 °C **smoothly through cold weather** (demand 6–8 kW, inside the pump's modulating band). Fuzzy on/off cycling survives **only in the two mildest outdoor windows** (outdoor ≳ 9 °C → demand < 4 kW floor) plus a startup transient as the wall mass charges from its 20 °C initial condition. This is the expected, correct behaviour: the mass now does its job, and the residual cycling is the HP floor, not the math.

**Where that leaves us.** [Likely] The **plant and comfort behaviour are validated and realistic.** The **cost-optimisation objective — the actual thesis contribution — is not yet implemented** in the MATLAB track.

---

## 7. Companion Python / RL track (from project records)

*(Summarised from the project log; files not re-read for this document.)*

- **SAC single-building result: locked.** [Likely] Comfort competitive with a rule-based baseline; price-responsiveness demonstrated. This is a complete, defensible thesis result on its own.
- **Multi-building generalisation (TABULA fleet): characterised failure.** [Likely] Persistent over/under-heating from reward asymmetry and policy collapse (feedforward, ignoring room-temp feedback). Either fix, or document as a result.
- **Python MPC baseline: exists, comparison not yet valid.** [Likely] Disturbance-scaling asymmetry between MPC and the gym env; `--grid_on` defaults False, so **price-aware optimisation was not active** in completed runs.
- Stack: 4R3C/3R2C thermal model, CVXPY/CLARABEL, Stable-Baselines3 SAC. Key lesson: pair `best_model.zip` with the **matching** `vecnormalize_{N}_steps.pkl`.

---

## 8. What still needs to be implemented (prioritised)

**MATLAB track**
1. **Wire ENTSO-E price into the MPC objective** — the core missing feature; converts setpoint-tracking into cost-minimisation. [highest priority]
2. **Fix `fix_mpc_codegen.m`** — update its embedded params to the real building + drop the fixed T_supply, or retire it. (Footgun until done.)
3. **Confirm θe / refine UA 366 → ~345** — read the Norm-Außentemperatur off the Vonovia sheet; pull any component-area table to replace the back-solved window area and the 72 Wh/m²K guess.
4. **Upgrade controller model 1R1C → 2R2C** — needed for credible load-shifting.
5. **Resolve T_supply architecture** — `nlmpc` vs gain-scheduling.
6. **(Optional) add a buffer-tank model** — to reproduce the real anti-cycling behaviour instead of raw room cycling.
7. Add a guard/log on the 30 kW resistive fallback.

**Python track**
8. Re-run MPC-vs-SAC with `--grid_on` active and consistent disturbance scaling.
9. Fix multi-building RL generalisation, or finalise it as a documented failure mode.

---

## 9. Are we where we want to be?

**Partly — and honestly so.**

- **Infrastructure: done.** [Certain] Real building, real HP physics, real weather, working Adaptive-MPC loop, realistic multi-timescale plant. The hard modelling is behind us.
- **Comfort control: working and validated.** [Likely] Smooth tracking in the regime that matters; residual cycling explained and attributable to a real actuator limit.
- **The thesis contribution — cost-aware load-shifting — is NOT yet demonstrated in MATLAB.** [Certain] Price isn't in the objective; the 1R1C controller model can't yet exploit storage. The Python/SAC side *has* shown price-responsiveness single-building, so the concept is proven on one track.

**One-line status:** the simulator is real and trustworthy; the next block of work is turning the controller from "hold 20 °C" into "hold 20 °C for the least money," starting with wiring the price signal and moving to a 2R2C model.

---

## 10. Immediate next steps

1. Locate θe on the Vonovia sheet → lock UA (and window area) to documented values.
2. Wire the ENTSO-E price series into the MPC cost function (both tracks).
3. Update or retire `fix_mpc_codegen.m` so it can't silently revert the building.
4. Upgrade the MATLAB controller model to 2R2C, then re-run the price-aware comparison.
