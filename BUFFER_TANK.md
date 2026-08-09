# Buffer Tank Integration — Kermi x-buffer compact cool 500

**Project:** OPTIHEAT — Virchowstr. 6, Langenhagen
**Model:** `HouseHeatingSystem.slx` (MATLAB/Simulink Adaptive MPC track)
**Status:** Plant side complete. Controller side (2-state MPC) pending.

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

### Tank standing loss, 1.9 W/K — [Guessing]

Not available in the Planunterlagen. Estimated from geometry:

```
Cylinder D = 0.75 m, H = 1.631 m
A ≈ π·0.75·1.631 + 2·π·0.375² ≈ 4.73 m²
U ≈ 0.4 W/(m²·K)   (~100 mm PU, λ ≈ 0.04)
UA_tank ≈ 4.73 × 0.4 ≈ 1.9 W/K
```

**Should be replaced with the Kermi datasheet standby-loss figure when available** (ErP class, kWh/24 h at 45 K ΔT). At 40 °C tank and 15 °C plant room this gives ≈ 47 W — small relative to the 4 kW compressor floor, so the estimate is not load-bearing for the main result.

### Plant room temperature, 15 °C — [Guessing]

Unheated basement technical room. Not measured.

---

## 6. How it works

Two coupled energy balances:

```
C_tank · dT_tank/dt = Q_hp − H_rad·(T_tank − T_room) − UA_tank·(T_tank − T_tech)
C_air  · dT_room/dt =        H_rad·(T_tank − T_room) − UA·(T_room − T_out)
```

with `H_rad = 312`, `UA_tank = 1.9`, `UA = 366`, `C_tank = 2.093e6`, `C_air = 7.46e7`.

Tank time constant:

```
τ_tank = C_tank / (H_rad + UA_tank) = 2.093e6 / 314 ≈ 6660 s ≈ 1.85 h
```

Store capacity:

| Swing | Energy |
|---|---|
| 55 → 45 °C | 5.8 kWh |
| 55 → 35 °C | 11.6 kWh |

Against a 10.97 kW design load that is roughly **1 hour of full-load autonomy**; at a mild-day 3 kW load, about 4 hours. Meaningful for cycle reduction and intraday price dips, not for multi-hour shifting. The building mass (τ ≈ 57 h) remains by far the larger store — worth stating explicitly rather than overselling the tank.

---

## 7. Expected behaviour

A smoke test should be run over ~3 days starting in a **mild shoulder period** (e.g. 2025-10-15). July is above the 15 °C Heizgrenze, so the heat pump stays off and the test would show nothing.

Four checks:

1. **`Ttank` reads 30–50, not ~313** — confirms the PS-Simulink Converter is in °C with affine conversion, not Kelvin.
2. **`Ttank` drifts smoothly and does not go negative** — confirms Temperature Source port orientation (a reversed source pulls the node toward −288 °C).
3. **`Ttank` sits above `Troom`** — confirms emitter direction; heat must flow tank → room.
4. **Room sawtooth is slower and shallower than the pre-tank July run** — the tank is absorbing the compressor floor. This is the headline result.

Expected steady state with the HP at its 4 kW floor:

```
312 · (T_tank − T_room) + losses ≈ 4000 W  →  T_tank ≈ T_room + 13 K
```

so the tank parks around 33 °C during mild weather.

---

## 8. Known limitations

**The emitter is an unconditional conductance.** Heat flows whenever `T_tank > T_room`, with no pump or mixer gating. The real installation has pumps M31.1/M31.2 and 3-way mixer M41 controlling that draw. Consequence: **the tank self-discharges as fast as it is charged.** The current build therefore delivers cycle reduction but very little price-shifting capability. Adding a pump gate — draw only when the room actually calls for heat — is the natural next increment and is what turns the buffer into a genuine store.

This is a defensible v1 because it isolates the anti-cycling effect from the load-shifting effect, which are separate claims.

**The 6 kW Heizstab is not modelled.** Only relevant below roughly −5 °C outdoor, where the HP (8.67 kW at −15 °C) cannot meet the ~11 kW load. It runs at COP 1, roughly double the cost per kWh of heat versus the heat pump at cold conditions, so it matters for winter cost figures. Decision pending on whether to implement it as a plant-side rule (keeps one MV) or a second MPC decision variable.

**The MPC internal model is still 1R1C.** The controller does not know the tank exists and predicts as though it heats the room directly. Control quality will be poor until step 3 upgrades `getAdaptivePlant` to a 2-state model. This is expected, not a fault.

**`HP Physics` still takes `T_supply_C` from the Heating Curve.** The condenser temperature should be `Ttank`, since with a buffer the flow temperature is a state rather than a weather function. Rewiring is pending; the heating curve's role changes from "actual supply temperature" to "tank charging setpoint".

**Single-node, fully mixed.** No stratification. Justified by the single real sensor B38, but it does mean the model cannot represent a hot top layer serving the circuit while the bottom is still cold.

---

## 9. Outstanding items

| # | Item |
|---|---|
| 1 | Replace estimated `UA_tank = 1.9 W/K` with Kermi datasheet standby loss |
| 2 | Step 3 — `getAdaptivePlant` 1R1C → 2-state; re-add Mux to `mo` as `[Troom; Ttank]` |
| 3 | Step 4 — rewire `HP Physics` `T_supply_C` from Heating Curve to `Ttank` |
| 4 | Decide Heizstab treatment (plant-side rule vs. second MV) |
| 5 | Add pump/mixer gate on the emitter to enable real load shifting |
| 6 | `analyze_run` — log and plot `Ttank`; name the top-level line `Ttank` |
