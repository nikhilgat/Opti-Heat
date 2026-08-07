function plant_d = getAdaptivePlant(T_air_C, T_supply_C, Ts, Req, C_air)
%GETADAPTIVEPLANT Build discrete plant with HP-derived Qmax at current T_air.
% Replaces the fixed-Qmax resistive-heater assumption in
% HouseHeatingSystemExample.m with the real IDM ALM 4-12 capacity at the
% current outdoor/supply temperature. Called every control interval by
% the adaptive MPC loop (run_adaptive_mpc_hp.m).

Qmax_W = hp_capacity_lookup(T_air_C, T_supply_C, 'max');

A = -1 / (Req * C_air);
B = [Qmax_W / C_air, 1 / (Req * C_air)];   % [MV (HP), MD (Weather)]
C_mat = 1;
D_mat = [0, 0];

plant_c = ss(A, B, C_mat, D_mat);
plant_d = c2d(plant_c, Ts);
plant_d = setmpcsignals(plant_d, 'MV', 1, 'MD', 2);

end
