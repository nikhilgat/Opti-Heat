function T_supply_C = heating_curve(T_air_C)
%HEATING_CURVE Weather-compensated supply temp for the radiator system.
% Design point: 55C supply at -10C outdoor (radiator design, 55/45/20).
% Upper point: 35C supply at 15C outdoor (heating limit / min useful flow).
% Linear between, clamped outside.

T1_air = -10; T1_sup = 55;
T2_air =  15; T2_sup = 35;

if T_air_C <= T1_air
    T_supply_C = T1_sup;
elseif T_air_C >= T2_air
    T_supply_C = T2_sup;
else
    T_supply_C = T1_sup + (T_air_C - T1_air) * (T2_sup - T1_sup) / (T2_air - T1_air);
end
end
