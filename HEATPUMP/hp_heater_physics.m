function [Heat_W, Elec_W, duty] = hp_heater_physics(u_MPC, T_air_C, T_supply_C)
%HP_HEATER_PHYSICS Duty-cycle-averaged IDM ALM 4-12 output.
%
% u_MPC: continuous control signal from the MPC, 0..1, interpreted as a
%        fraction of MAXIMUM thermal capacity. Heat_W = u_MPC * Qmax
%        exactly, which is precisely what the MPC's internal B matrix
%        assumes -- see idm_alm412_interpolants.m for why that matters.
%
% Third output DUTY is the fraction of the control interval the compressor
% actually runs: 0 = off, 1 = continuous modulated running, and anything
% between means one on/off cycle inside the interval because demand fell
% below the ~4 kW modulation floor. analyze_run.m counts compressor starts
% from this, which is the honest short-cycling metric. Counting rising
% edges of u_MPC is NOT: under the old physics law the compressor never
% stopped, so that number measured the controller changing its mind.
%
% Heizgrenze: the heat pump is hard-gated off once outdoor air reaches
% the heating limit (see heating_curve.m, HEATING_LIMIT_C = 15 C). This
% overrides the MPC command, so a summer start date no longer heats the
% building all season.
%
% Envelope: the datasheet grids are NaN-filled inside
% idm_alm412_interpolants.m by holding the highest achievable flow
% temperature, so the interpolants no longer return NaN. Out-of-envelope
% operating points warn once and use the clamped datasheet value; a
% genuine NaN is a bug and raises an error rather than being papered over.

persistent hp warnedEnvelope
if isempty(hp)
    hp = idm_alm412_interpolants();
end
if isempty(warnedEnvelope)
    warnedEnvelope = false;
end

% --- Heating limit gate (Heizgrenze) ---
[~, heating_on] = heating_curve(T_air_C);
if ~heating_on
    Heat_W = 0;
    Elec_W = 0;
    duty   = 0;
    return
end

% --- Envelope check: warn once if we are running on clamped data ---
if ~warnedEnvelope && ~hp.inEnvelope(T_air_C, T_supply_C)
    warning('hp_heater_physics:outsideEnvelope', ...
        ['Operating point T_air = %.1f C, T_supply = %.1f C is outside the ' ...
         'measured IDM ALM 4-12 envelope (max supply here is %.1f C). ' ...
         'Using clamped datasheet values. This warning is issued once.'], ...
        T_air_C, T_supply_C, hp.maxValidSupply(T_air_C));
    warnedEnvelope = true;
end

perf = hp.getPerformance(T_air_C, T_supply_C, u_MPC);

if isnan(perf.Pth) || isnan(perf.Pel)
    error('hp_heater_physics:nanPerformance', ...
        ['NaN heat pump performance at T_air = %.1f C, T_supply = %.1f C, ' ...
         'u = %.3f. The interpolant grids are NaN-filled, so this indicates ' ...
         'a bug in idm_alm412_interpolants.m rather than a missing data point.'], ...
        T_air_C, T_supply_C, u_MPC);
end

% Convert kW to W for the Simulink thermal network
Heat_W = perf.Pth * 1000;
Elec_W = perf.Pel * 1000;
duty   = perf.duty;
end
