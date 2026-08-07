function [Heat_W, Elec_W] = hp_heater_physics(u_MPC, T_air_C, T_supply_C)
%HP_HEATER_PHYSICS Modulated IDM ALM 4-12 output.
% u_MPC: Continuous control signal from MPC (0 to 1).
% Outside datasheet envelope (NaN) -> falls back to scaled resistive heater.

RESISTIVE_FALLBACK_W = 30162;

persistent hp
if isempty(hp)
    hp = idm_alm412_interpolants();
end

% Get the modulated performance based on current temps and MPC request
perf = hp.getPerformance(T_air_C, T_supply_C, u_MPC);

if isnan(perf.Pth) || isnan(perf.Pel)
    % Fallback if outside weather boundaries
    Heat_W = RESISTIVE_FALLBACK_W * u_MPC;
    Elec_W = RESISTIVE_FALLBACK_W * u_MPC;
else
    % Convert kW to W for the Simulink thermal network
    Heat_W = perf.Pth * 1000;
    Elec_W = perf.Pel * 1000;
end
end