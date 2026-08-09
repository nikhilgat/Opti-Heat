function [T_supply_C, heating_on] = heating_curve(T_air_C)
%HEATING_CURVE Weather-compensated supply temp for the radiator system.
% Design point: 55C supply at -10C outdoor (radiator design, 55/45/20).
% Upper point: 35C supply at 15C outdoor (heating limit / min useful flow).
% Linear between, clamped outside.
%
% Second output HEATING_ON is the Heizgrenze (heating limit) gate:
% false once outdoor air reaches HEATING_LIMIT_C, so the heat pump is
% held off through the non-heating season instead of tracking the curve
% all summer. T_supply_C is still returned at its clamped minimum when
% off, so downstream COP/capacity interpolants never see an invalid
% temperature. This constant is the single source of truth for the
% heating limit -- hp_heater_physics.m reads it from here.

HEATING_LIMIT_C = 16;

T1_air = -10; T1_sup = 55;
T2_air =  15; T2_sup = 35;

if T_air_C <= T1_air
    T_supply_C = T1_sup;
elseif T_air_C >= T2_air
    T_supply_C = T2_sup;
else
    T_supply_C = T1_sup + (T_air_C - T1_air) * (T2_sup - T1_sup) / (T2_air - T1_air);
end

heating_on = T_air_C < HEATING_LIMIT_C;
end
