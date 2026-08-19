# Buffer Tank Integration — Kermi x-buffer compact cool 500

**Project:** OPTIHEAT — Virchowstr. 6, Langenhagen
**Model:** `HouseHeatingSystem.slx` (MATLAB/Simulink Adaptive MPC track)
**Status:** Plant side complete, including TRV throttling (§6). Controller side is now a working 2-state (room+tank) MPC with price in the objective (see `OPTIHEAT_PROJECT_STATUS.md` §4/§5 for the current, load-shifting-focused status — this file stays focused on the tank/emitter hardware and physics).

---

## 1. Why the tank was added

The IDM AERO ALM 4-12 has a compressor minimum modulation floor of **~4.0 kW thermal**, effectively constant across the whole datasheet envelope. The building's heat demand is:

```
Q_load = UA · (T_room − T_out) = 366 · (20 − T_out)
```

| T_out | Q_load | HP minimum |
|---|---|---|
| 9.1 °C | 4.0 kW | 4.0 kW |
| 12 °C | 2.9 kW | 4.0 kW |
| 14 °C | 2.2 kW | 4.0 kW |

Above roughly **9 °C outdoor the machine physically cannot modulate down to the load.** Without a buffer, that surplus goes straight into the room air: a July test run showed the room sawtoothing between 18 °C and 28 °C with a burst period of ~2000 s, driven entirely by the compressor cutting in and out around the floor.

The 500 L buffer gives the compressor somewhere to park its minimum output that is not the occupied space.

---

## 2. Hardware being represented

Confirmed from the as-built hydraulic scheme `LAN_Vir.6_HZ_SC_28.03.2025` (page 1 of the Planunterlagen):

| Item | Value |
|---|---|
| Model | Kermi x-buffer compact cool 500 |
| Label on drawing | **"Pufferspeicher HZ Nr.1"** (heating buffer) |
| Volume | 500 L |
| Geometry | 1631 mm high, 750 × 650 mm footprint, 4 × R1½" |
| DHW | **Separate** — own Warmwasserspeicher + Frischwasserstation (M64, B42) |
| Tank sensor | **B38 Heizungspeicherfühler — a single sensor** |
| Backup heater | Inneneinheit **6 kW Heizstab** (not yet modelled) |
| Design load | Heizkreis Q = 10.97 kW |
| HP primary | 55/50 °C, ΔT 5 K, 1.89 m³/h |
| Heating circuit | 55/45 °C, ΔT 10 K, 0.94 m³/h |

Two consequences worth noting. The buffer is **heating-only**, so there is no legionella floor and no DHW draw competing for the store — the tank is free to be used for load shifting. And because the real installation has **only one tank sensor (B38)**, a single-node fully-mixed tank model matches exactly what the real controller can observe. The 1-node simplification is therefore defensible on control-theoretic grounds, not just computational ones.

---

## 3. Where it sits in the model

All tank blocks were placed **inside the `Heat Pump (IDM AERO ALM 4-12)` subsystem**, not at the top level. This keeps the top-level diagram unchanged apart from one new outport.

### Before

```
HP Physics ──> Heat Flow Source ──> Heat_Out ──> House Thermal Network
```

The heat pump heated the room air node directly.

### After

```
HP Physics ──> Heat Flow Source ──> Buffer Tank node
                                         │
                                         ├── Emitter ────────> Heat_Out ──> House Thermal Network
                                         ├── Tank Loss ── Temp Source ── Thermal Reference
                                         └── Temperature Sensor ──> PS-Simulink ──> Ttank (outport 2)
```

The heat pump now charges water; the building draws from that water through the emitter. The tank sits between them as a thermal capacitance.

---

## 4. Blocks added

All from Simscape ▸ Foundation Library ▸ Thermal.

| Block | Name | Library group | Parameters |
|---|---|---|---|
| Thermal Mass | `Buffer Tank` | Thermal Elements | Mass `500` kg, Specific heat `4186` J/(K·kg), Initial temp `313.15` K (40 °C), graphical ports `2` |
| Convective Heat Transfer | `Emitter` | Thermal Elements | Area `1` m², coefficient `312` W/(K·m²) |
| Convective Heat Transfer | `Tank Loss` | Thermal Elements | Area `1` m², coefficient `1.9` W/(K·m²) |
| Temperature Source | — | Thermal Sources | `288.15` K (15 °C plant room) |
| Thermal Reference | — | Thermal Elements | — |
| Temperature Sensor | — | Thermal Sensors | Measurement type **Absolute** |
| PS-Simulink Converter | — | Simscape ▸ Utilities | Output unit `degC`, **Apply affine conversion ticked** |
| Outport | `Ttank` | Simulink ▸ Sources/Sinks | — |

For the two Convective Heat Transfer blocks only the **product** Area × coefficient matters; Area is set to 1 m² so the coefficient reads directly as the conductance in W/K.

**TRV valve chain, added since the table above was written.** The `Emitter` block's coefficient is no longer the fixed 312 W/K constant shown in the table — it is driven by a small chain feeding the block's coefficient input: a `Constant` (21, the valve shut-off temperature) minus the current room temperature, through a `Gain` (312), through a `Saturation` block limited to `[3.12, 312]`. This reproduces `h_trv = clamp(312·(21−T_room), 3.12, 312)` inside the Simscape plant itself (see §6). **If the Saturation upper and lower limits are ever set equal, the whole valve chain goes dead and the emitter reverts to running wide open regardless of room temperature** — worth checking first if tank behaviour ever looks wrong.

---

## 5. Parameter derivation

### Tank capacitance — [Certain]

```
C_tank = 500 kg × 4186 J/(kg·K) = 2.093e6 J/K
```

### Emitter conductance, 312 W/K — [Likely]

Not the radiator surface conductance. Because the tank is modelled as a single fully-mixed node, the Emitter block is driven by `T_tank − T_room`, which at design conditions is 55 − 20 = **35 K**, not the 29.7 K LMTD of the radiator itself.

```
H_eff = Q_design / (T_supply,design − T_room,design)
      = 10968 W / (55 − 20) K
      = 312 W/K
```

Cross-check against the design flow rate on the scheme:

```
ṁ·cp  = 0.94 m³/h → 0.261 kg/s × 4186 = 1093 W/K
Q_des = 1093 × (55 − 45) = 10.93 kW   ✓ matches "Heizkreis Q = 10,97 kW"
```

This lumped value deliberately bundles the emitter conductance **and** the circuit flow-rate limit, which is what a single-node mixed tank requires. An earlier value of 369 W/K (derived from LMTD) was wrong for this model structure and over-delivered heat by ~18 %.

### Tank standing loss, 1.9 W/K — [Estimated]

Not available in the Planunterlagen. Estimated from geometry:

```
Cylinder D = 0.75 m, H = 1.631 m
A ≈ π·0.75·1.631 + 2·π·0.375² ≈ 4.73 m²
U ≈ 0.4 W/(m²·K)   (~100 mm PU, λ ≈ 0.04)
UA_tank ≈ 4.73 × 0.4 ≈ 1.9 W/K
```

**Should be replaced with the Kermi datasheet standby-loss figure when available** (ErP class, kWh/24 h at 45 K ΔT). At 40 °C tank and 15 °C plant room this gives ≈ 47 W — small relative to the 4 kW compressor floor, so the estimate is not load-bearing for the main result.

### Plant room temperature, 15 °C — [Estimated]

Unheated basement technical room. Not measured.

---

## 6. How it works

Two coupled energy balances, now with the emitter conductance **throttled by a thermostatic radiator valve (TRV)** rather than fixed:

```
h_trv = clamp( H_rad·(T_trv_set − T_room), H_RAD_MIN, H_rad )     -- valve position, recomputed every step

C_tank · dT_tank/dt = Q_hp − h_trv·(T_tank − T_room) − UA_tank·(T_tank − T_tech)
C_air  · dT_room/dt =        h_trv·(T_tank − T_room) − UA·(T_room − T_out)
```

with `H_rad = 312`, `H_RAD_MIN = 3.12`, `T_trv_set = 21` (Virchowstr. 6's manual TRVs sit at position 2-3), `UA_tank = 1.9`, `UA = 366`, `C_tank = 2.093e6`, `C_air = 7.46e7`.

**This is the mechanism that actually lets the tank hold charge.** With `h_trv` fixed at 312 (the old model), heat flows into the room as fast as the tank-room ΔT allows, and the tank self-discharges about as fast as it's charged — a damper, not a store. The TRV closes as the room approaches 21°C (fully open at ≤20°C, shut at 21°C, a 1K proportional band), so once the room is comfortable the valve throttles the draw and the tank can actually run hot. §8 covers what this does and doesn't buy in practice.

Tank time constant (valve fully open, worst case for how fast it self-discharges):

```
τ_tank = C_tank / (H_rad + UA_tank) = 2.093e6 / 314 ≈ 6660 s ≈ 1.85 h
```

With the valve throttled towards 21°C, the effective time constant is longer — `h_trv` can fall as low as 3.12 W/K, stretching `τ_tank` towards `2.093e6/5 ≈ 4.2e5 s ≈ 116 h` in the limit.

Store capacity:

| Swing | Energy |
|---|---|
| 55 → 45 °C | 5.8 kWh |
| 55 → 35 °C | 11.6 kWh |

Against a 10.97 kW design load that is roughly **1 hour of full-load autonomy**; at a mild-day 3 kW load, about 4 hours. Meaningful for cycle reduction and intraday price dips, not for multi-hour shifting. The building mass (τ ≈ 57 h) remains by far the larger store — worth stating explicitly rather than overselling the tank.

---

## 7. Expected behaviour — now measured, not just predicted

The four original smoke-test checks below all pass in current short runs (`init_adaptive_mpc.m` → `analyze_run.m`, 1-2 day windows — see `OPTIHEAT_PROJECT_STATUS.md` §5 item 1 for the full results across three weather regimes):

1. **`Ttank` reads 30–50, not ~313** — confirmed; typical runs show `Ttank` in the high-20s to low-40s °C depending on season.
2. **`Ttank` drifts smoothly and does not go negative** — confirmed.
3. **`Ttank` sits above `Troom`** — confirmed **except during a Heizgrenze cutoff that runs long enough to draw the tank down toward room temperature**, at which point the emitter has nothing left to deliver and the room starts falling too (see `OPTIHEAT_PROJECT_STATUS.md` §5 item 1 for the traced example — tank fell to 17.5°C, below the room, during an extended afternoon cutoff). This is the current live edge case, not a modelling bug.
4. **Room sawtooth is slower and shallower than the pre-tank July run** — confirmed; the tank measurably absorbs the compressor floor (see §8).

Expected steady state with the HP at its 4 kW floor, valve fully open (`h_trv=312`, i.e. room at or below 20°C):

```
312 · (T_tank − T_room) + losses ≈ 4000 W  →  T_tank ≈ T_room + 13 K
```

but with the TRV throttling as the room approaches 21°C, the same 4 kW needs a much larger ΔT to get through a smaller `h_trv` — this is exactly the mechanism that lets the tank run hotter (and hold more usable charge) once the room is comfortable, at the cost of needing more tank-side temperature to push the same power through.

---

## 8. Known limitations

**The emitter is throttled by the TRV, not gated by a pump.** ✅ **Resolved differently than originally planned.** The original plan here was a pump/mixer gate (draw only when the room calls for heat, mirroring the real M31.1/M31.2 + M41 hardware). What was actually built instead is the TRV valve law in §6 — a continuous, physically-motivated throttle rather than a binary gate, and it achieves the same goal (letting the tank hold charge) by a different, simpler mechanism already present in the real building (residents' thermostatic valves). **Net effect measured, not just modelled:** the tank now genuinely holds charge and swings independently of room temperature across short test runs — see `OPTIHEAT_PROJECT_STATUS.md` §5 item 1. It is not, however, a complete fix for load-shifting: that same document traces a specific failure mode where an extended Heizgrenze cutoff can still draw the tank down far enough to lose its ΔT advantage over the room. A literal pump gate was not found necessary to get this far, but is not ruled out as a future refinement either.

**The MPC internal model is now 2-state.** ✅ **Resolved.** `getAdaptivePlant.m` predicts `x=[T_room;T_tank]`, including the TRV law, and the live "MPC Prediction Model" Stateflow chart calls it every control step with the real current room temperature. See `OPTIHEAT_PROJECT_STATUS.md` §4.

**The 6 kW Heizstab is not modelled.** Still open. Only relevant below roughly −5 °C outdoor, where the HP (8.67 kW at −15 °C) cannot meet the ~11 kW load. It runs at COP 1, roughly double the cost per kWh of heat versus the heat pump at cold conditions, so it matters for winter cost figures. Decision pending on whether to implement it as a plant-side rule (keeps one MV) or a second MPC decision variable.

**`HP Physics` still takes `T_supply_C` from the Heating Curve, not `Ttank`.** Still open. The condenser temperature should be a function of the tank state, since with a buffer the flow temperature is a state rather than a weather function. Rewiring is pending; the heating curve's role would change from "actual supply temperature" to "tank charging setpoint".

**Single-node, fully mixed.** No stratification. Justified by the single real sensor B38, but it does mean the model cannot represent a hot top layer serving the circuit while the bottom is still cold.

**The MPC's prediction of tank charging capacity is frozen per control step, not scheduled across the horizon.** New finding, 2026-08-19 — see `OPTIHEAT_PROJECT_STATUS.md` §5 item 1 for the full trace. The Adaptive MPC re-linearises from the current operating point and holds that model fixed for the whole 24 h prediction, so it cannot foresee the tank's charging capacity (`Qmax_W`) dropping to zero when outdoor temperature crosses the 15°C Heizgrenze partway through the horizon. This is the main reason the tank sometimes isn't pre-charged enough heading into a cutoff, and it's an MPC-architecture question, not a tank-hardware one.

---

## 9. Outstanding items

| # | Item | Status |
|---|---|---|
| 1 | Replace estimated `UA_tank = 1.9 W/K` with Kermi datasheet standby loss | Open |
| 2 | `getAdaptivePlant` 1R1C → 2-state; reconnect `mo` Mux as `[Troom; Ttank]` | ✅ Done |
| 3 | Rewire `HP Physics` `T_supply_C` from Heating Curve to `Ttank` | Open |
| 4 | Decide Heizstab treatment (plant-side rule vs. second MV) | Open |
| 5 | ~~Add pump/mixer gate on the emitter~~ — superseded by the TRV valve law (§6/§8) | ✅ Done (different mechanism) |
| 6 | `analyze_run` — log and plot `Ttank`; name the top-level line `Ttank` | ✅ Done |
| 7 | Give the MPC foresight of the Heizgrenze cutoff within its own prediction horizon | Open — see `OPTIHEAT_PROJECT_STATUS.md` §5 item 1 / §8 item 1, highest priority |
