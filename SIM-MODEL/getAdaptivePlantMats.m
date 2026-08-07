function [A,B,C,D] = getAdaptivePlantMats(T_air_C, T_supply_C, Ts, Req, C_air)
%GETADAPTIVEPLANTMATS Extrinsic-friendly wrapper: returns discrete A,B,C,D
% matrices (not an ss object) so a MATLAB Function block can assign them
% to pre-sized outputs.
plant_d = getAdaptivePlant(T_air_C, T_supply_C, Ts, Req, C_air);
A = plant_d.A;
B = plant_d.B;
C = plant_d.C;
D = plant_d.D;
end
