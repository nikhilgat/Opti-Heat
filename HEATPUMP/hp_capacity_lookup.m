function Q_W = hp_capacity_lookup(T_air_C, T_supply_C, mode)
%HP_CAPACITY_LOOKUP Scalar thermal capacity [W] from IDM ALM 4-12 interpolants.
% mode: 'max' or 'min' modulation.
% Outside datasheet envelope (NaN) -> falls back to resistive heater
% capacity (Qmax = 30162 W, from BasicHeater_HouseHeatingSystemExample.m).

RESISTIVE_FALLBACK_W = 30162;

persistent hp
if isempty(hp)
    hp = idm_alm412_interpolants();
end

switch mode
    case 'max'
        Q_kW = hp.getPthMax(T_air_C, T_supply_C);
    case 'min'
        Q_kW = hp.getPthMin(T_air_C, T_supply_C);
    otherwise
        error('hp_capacity_lookup: mode must be ''max'' or ''min'', got %s', mode);
end

if isnan(Q_kW)
    Q_W = RESISTIVE_FALLBACK_W;
else
    Q_W = Q_kW * 1000;
end
end
