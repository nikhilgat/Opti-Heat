function plant_d = getAdaptivePlant(T_air_C, T_supply_C, Ts, Req, C_air, C_tank, H_rad, T_room_C, T_trv_set)
%GETADAPTIVEPLANT Build the discrete 2-state plant for the adaptive MPC.
%
% States  x = [T_room ; T_tank]
% Inputs  u = [u_hp (MV, 0-1) ; T_out (MD)]
% Outputs y = [T_room ; T_tank]      (both measured -- B38 exists in reality)
%
%   C_air  * dT_room/dt = h_trv*(T_tank - T_room) - UA*(T_room - T_out)
%   C_tank * dT_tank/dt = Qmax*u_hp - h_trv*(T_tank - T_room)
%
% The heat pump charges the buffer tank; the building draws from the tank
% through the emitter. This is what lets the controller reason about
% STORED energy -- a room-only model has no state representing the tank,
% so it cannot plan "charge now, coast later".
%
% THERMOSTATIC RADIATOR VALVES (new). Virchowstr. 6 has manual TRVs, set
% by residents to roughly position 2-3 (~21 C). The emitter coefficient is
% therefore NOT the constant 312 W/K assumed before -- it is throttled:
%
%   h_trv = clamp( H_rad * (T_trv_set - T_room) , H_RAD_MIN , H_rad )
%
% With H_rad = 312 W/K and T_trv_set = 21 C this gives a 1 K proportional
% band: fully open at 20 C and below (so the full 312 W/K needed to meet
% the design load at 55/20 is available at setpoint), closing linearly to
% shut at 21 C.
%
% This matters enormously. With the valves permanently open the tank is
% slaved to the room load and cannot hold charge -- it is a hydraulic
% decoupler, not a store. It is the closing of the valves that lets the
% tank run hot and be discharged later, which is the whole cycle-reduction
% and load-shifting mechanism. If the controller's model assumes a fixed
% 312 W/K while the plant throttles, the two disagree by up to two orders
% of magnitude in the emitter term, so h_trv must be recomputed here every
% control interval from the CURRENT room temperature.
%
% H_RAD_MIN mirrors the Simscape Convective Heat Transfer block's
% min_heat_tr_coeff (3.12 W/K); a hard zero makes the A matrix singular in
% the tank row and the emitter block clamps it anyway.
%
% Qmax is the real IDM ALM 4-12 capacity at the current outdoor/supply
% temperature, so the input gain is re-linearised every control interval.
%
% NOTE ON TANK STANDING LOSS: deliberately omitted from this controller
% model. UA_tank = 1.9 W/K gives ~48 W against ~7 kW January loads (0.7%),
% and including it would introduce an affine offset term that breaks the
% zero-nominal-point bookkeeping below for no useful accuracy. The
% Simscape plant still models it; MPC's output-disturbance integrator
% absorbs the resulting small bias.
%
% NOMINAL OPERATING POINT: the equations above are purely linear in the
% states and inputs -- there is no constant term. The correct nominal
% point for the Adaptive MPC block is therefore the ORIGIN
% (X = 0, U = 0, Y = 0, DX = 0), not [20; 40]. Declaring X = [20;40] with
% DX = [0;0] told the controller that a 40 C tank holds steady with the
% pump off, when these equations say it falls at ~10.7 K/h. See the
% MPC Prediction Model block.
%
% Trailing arguments are optional so older callers still work.

if nargin < 6 || isempty(C_tank),    C_tank    = 2.093e6; end  % 500 kg x 4186 J/kgK
if nargin < 7 || isempty(H_rad),     H_rad     = 312;     end  % 10968 W / (55-20) K
if nargin < 8 || isempty(T_room_C),  T_room_C  = 20;      end  % valve fully open
if nargin < 9 || isempty(T_trv_set), T_trv_set = 21;      end  % TRV shut-off point

H_RAD_MIN = 3.12;   % W/K, matches the Simscape emitter block's floor

UA = 1 / Req;

% --- Thermostatic valve position at the current room temperature ---
h_trv = H_rad * (T_trv_set - T_room_C);
h_trv = min(max(h_trv, H_RAD_MIN), H_rad);

Qmax_W = hp_capacity_lookup(T_air_C, T_supply_C, 'max');

A = [ -(h_trv + UA)/C_air ,   h_trv/C_air  ;
        h_trv/C_tank      ,  -h_trv/C_tank ];

B = [ 0             ,  UA/C_air ;      % [MV (HP), MD (Weather)]
      Qmax_W/C_tank ,  0        ];

C_mat = eye(2);
D_mat = zeros(2,2);

plant_c = ss(A, B, C_mat, D_mat);
plant_d = c2d(plant_c, Ts);
plant_d = setmpcsignals(plant_d, 'MV', 1, 'MD', 2);

end
