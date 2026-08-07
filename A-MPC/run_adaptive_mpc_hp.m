function [A,B,C,D,U,Y,X,DX] = run_adaptive_mpc_hp(T_air_C)
%RUN_ADAPTIVE_MPC_HP MATLAB Function block body for the Adaptive MPC
% Controller's 'model' inport. Paste this function's body into the
% MATLAB Function block (or point the block at this file). Outputs feed
% a Bus Creator with 8 inputs in THIS ORDER: A,B,C,D,U,Y,X,DX -- that
% order is fixed by the block (it replaces Model.A/B/C/D and
% Model.Nominal.U/Y/X/DX at each control interval).
%
% Block parameters: Simulate using = Interpreted Execution
% (getAdaptivePlant uses ss/c2d, not code-gen safe).
%
% Input T_air_C: wire from the existing [Tatm] Goto/From tag already in
% HouseHeatingSystem.slx.

Ts = 900;
T_supply_C = heating_curve(T_air_C);

% --- Virchowstr. 6 lumped RC for the MPC INTERNAL model ---
% Must match init_adaptive_mpc.m and the plant UA (patch_plant_to_virchowstr6.m).
% UA = 366 W/K -> Req = 1/366 ;  C = 72 Wh/m2K x 287.92 m2 = 7.46e7 J/K.
Req   = 1/366;
C_air = 7.46e7;
TinIC = 20;

plant_d = getAdaptivePlant(T_air_C, T_supply_C, Ts, Req, C_air);

A = plant_d.A;
B = plant_d.B;
C = plant_d.C;
D = plant_d.D;

U  = [0, T_air_C];
Y  = TinIC;
X  = TinIC;
DX = 0;

end
