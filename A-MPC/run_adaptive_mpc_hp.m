function [A,B,C,D,U,Y,X,DX] = run_adaptive_mpc_hp(T_air_C, T_room_C)
%RUN_ADAPTIVE_MPC_HP MATLAB Function block body for the Adaptive MPC
% Controller's 'model' inport (mirrors the live 'MPC Prediction Model'
% block in HouseHeatingSystem.slx -- keep these two in sync). Paste this
% function's body into the MATLAB Function block (or point the block at
% this file). Outputs feed a Bus Creator with 8 inputs in THIS ORDER:
% A,B,C,D,U,Y,X,DX -- that order is fixed by the block (it replaces
% Model.A/B/C/D and Model.Nominal.U/Y/X/DX at each control interval).
%
% Block parameters: uses the codegen-safe getAdaptivePlantMats wrapper
% (raw A,B,C,D, not an ss object), so this can run under code generation.
%
% Inputs:
%   T_air_C  -- wire from the existing [Tatm] Goto/From tag.
%   T_room_C -- wire from the plant's real Troom (House Thermal Network
%               output). REQUIRED: h_trv (the TRV/emitter conductance)
%               is a function of the CURRENT room temperature, not a
%               fixed value -- see getAdaptivePlant.m. Defaulting this to
%               a constant silently pins the valve fully open in the
%               controller's model regardless of the real plant, which
%               defeats the entire storage mechanism the buffer tank
%               depends on.
%
% 2-STATE MODEL (room + buffer tank):
%   A,B,C,D are all 2x2. U, Y, X, DX are COLUMN vectors (2x1) -- the
%   Adaptive MPC block's Matrix Signal Check rejects row vectors with
%   "must be a matrix signal of 2 rows and 1 columns".
%   The block's outputs MUST also be pre-sized to match, or the extrinsic
%   assignment silently leaves them at their initial zeros.

Ts = 900;
T_supply_C = heating_curve(T_air_C);

% --- Virchowstr. 6 lumped RC for the MPC INTERNAL model ---
% Must match init_adaptive_mpc.m and the plant UA (patch_plant_to_virchowstr6.m).
% UA = 366 W/K -> Req = 1/366 ;  C = 72 Wh/m2K x 287.92 m2 = 7.46e7 J/K.
Req       = 1/366;
C_air     = 7.46e7;
C_tank    = 2.093e6;   % 500 kg x 4186 J/kgK (Kermi x-buffer compact 500)
H_rad     = 312;       % 10968 W / (55-20) K -- emitter coeff, TRV fully open
T_trv_set = 21;        % TRV shuts at this room temperature

[A, B, C, D] = getAdaptivePlantMats(T_air_C, T_supply_C, Ts, Req, C_air, ...
                                     C_tank, H_rad, T_room_C, T_trv_set);

% Purely linear model, no constant term -> the ONLY consistent nominal
% point is the origin. [20;40] with DX=[0;0] asserts a 40 C tank holds
% steady with the pump off; it actually falls ~10.7 K/h at that point.
% That mismatch (not scaling down as the real state drifts further from
% [20;40], because the anchor never moved) is what drove the excess
% compressor cycling and the room/tank blowing through their bounds.
U  = [0; 0];
Y  = [0; 0];
X  = [0; 0];
DX = [0; 0];

end
