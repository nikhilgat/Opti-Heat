function [A,B,C,D] = getAdaptivePlantMats(T_air_C, T_supply_C, Ts, Req, C_air, C_tank, H_rad, T_room_C, T_trv_set)
%GETADAPTIVEPLANTMATS Extrinsic-friendly wrapper: returns discrete A,B,C,D
% matrices (not an ss object) so a MATLAB Function block can assign them
% to pre-sized outputs.
%
% Sizes for the 2-state model (room + tank):
%   A: 2x2   B: 2x2   C: 2x2   D: 2x2
% The MATLAB Function block MUST pre-size its outputs to match, or the
% assignment silently fails under code generation.
%
% T_room_C and T_trv_set feed the thermostatic-valve model in
% getAdaptivePlant: the emitter coefficient is throttled as the room
% approaches T_trv_set, so the current room temperature has to be passed
% in from the model every control interval.

if nargin < 6, C_tank    = []; end
if nargin < 7, H_rad     = []; end
if nargin < 8, T_room_C  = []; end
if nargin < 9, T_trv_set = []; end

plant_d = getAdaptivePlant(T_air_C, T_supply_C, Ts, Req, C_air, C_tank, ...
                           H_rad, T_room_C, T_trv_set);
A = plant_d.A;
B = plant_d.B;
C = plant_d.C;
D = plant_d.D;
end
