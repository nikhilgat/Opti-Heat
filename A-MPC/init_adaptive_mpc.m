%% Run this BEFORE opening/updating HouseHeatingSystem.slx
% The Adaptive MPC Controller block's InitFcn resolves plant_d0 and
% mpcobj from the base workspace at load time -- they must exist before
% Simulink parses the block mask.

Ts = 900;

% --- Virchowstr. 6 lumped RC for the MPC INTERNAL model ---
% UA = 366 W/K  (documented design load 10968 W / 30 K)
% C  = 7.46e7 J/K (72 Wh/m2K x 287.92 m2).  See virchowstr6_building.m.
%
% NOW 2-STATE (room + buffer tank). The 1R1C room-only model could not
% represent stored energy, so the controller had no way to plan "charge
% the tank now, coast on it later" -- the mechanism behind both cycle
% reduction and price-responsive operation.
Req    = 1/366;
C_air  = 7.46e7;
C_tank = 2.093e6;    % 500 kg x 4186 J/kgK (Kermi x-buffer compact 500)
H_rad  = 312;        % 10968 W / (55-20) K -- emitter, valves FULLY OPEN
TinIC  = 20;
TtankIC = 40;        % tank initial condition in the Simscape plant

% --- Thermostatic radiator valves (TRVs) ---
% Virchowstr. 6 has manual TRVs on position 2-3, i.e. roughly 21 C. The
% emitter is therefore throttled, not permanently open:
%
%   h_trv = clamp( H_rad*(T_trv_set - T_room), 3.12, H_rad )
%
% giving a 1 K proportional band: fully open at 20 C and below (so the
% full 312 W/K is available at setpoint, which the design load needs),
% shut at 21 C.
%
% THIS IS WHAT MAKES THE BUFFER TANK A STORE. With the valves permanently
% open the tank temperature is slaved to the room load and can never be
% charged -- it is a hydraulic decoupler only. The valves closing is what
% lets the tank run hot, which is the entire cycle-reduction and
% load-shifting mechanism.
%
% In the Simulink plant these two numbers are the Constant block (21) and
% the Gain block (312) inside the Heat Pump subsystem, feeding the
% Saturation block, whose limits must be [3.12, 312]. If the Saturation
% upper and lower limits are equal the whole valve chain is dead and the
% emitter runs wide open regardless of what is set here.
T_trv_set = 21;      % C, valve fully shut at this room temperature
h_trv_min = 3.12;    % W/K, matches the Simscape emitter block floor

% --- Price weight (lambda) ---
% Scales how hard the controller is penalised for running the compressor,
% relative to the electricity price at that moment. See the price section
% further down for the full reasoning. Sweep this: too small and nothing
% shifts, too large and the controller under-heats to save money.
PRICE_WEIGHT = 0.2;

% --- Room operating point ---
% The reference is 20.75 C, NOT 20 C, and this is the single most
% important number for whether storage works at all.
%
% The TRV law is h = clamp(312*(21 - T_room), 3.12, 312). The clamp binds
% for any room temperature at or below 20 C, so the valve is FULLY OPEN
% throughout the range 18-20 C and only begins to throttle above 20 C.
% Earlier runs parked the room at 19 C, where the valve is pinned wide
% open, the tank drains into the building as fast as it is filled, and no
% amount of price weighting can produce load shifting -- that is the
% "valves permanently open" case, despite the TRV model being present.
%
% Usable building storage is therefore the 20-21 C band where the valve
% actually modulates (~20.7 kWh), not 19-21 C. Sitting at 19 C gives
% access to none of it. 20.75 C puts the operating point inside the
% throttling band, with room to be pushed down towards 20 C during
% expensive hours and up towards 21 C when power is cheap. That swing IS
% the storage mechanism.
%
% It is also the more honest figure: residents set these valves to
% position 2-3, so the building really does run near 21 C, not 19 C.
% JANUARY RESULT AND WHY 20.75 WAS TOO HIGH. At 20.75 C the valve is
% three-quarters shut: h = 312*(21 - 20.75) = 78 W/K. The January load at
% -2 C outdoor is ~8.3 kW, which through a 78 W/K emitter would need a
% tank at 20.75 + 8300/78 = 127 C. Impossible, so the controller pinned
% the tank against its 55 C ceiling (mean 52.7 C) and let the room sag
% until the valve opened far enough to pass the load. The cost: standing
% loss up 56 % (16.5 -> 25.8 kWh) and total energy up 5 %.
%
% 20.2 C leaves the valve ~80 % open, which is enough authority to meet
% the design-season load without driving the tank to its limit, while
% still sitting inside the throttling band rather than below it.
%
% THE DEEPER POINT, which is a physical result rather than a tuning
% choice: in mid-winter the emitter must be nearly fully open just to meet
% the load, so there is no spare valve authority and therefore no usable
% storage. The throttling that would let the building bank heat is exactly
% the throttling it cannot afford when it is cold. This is why every
% configuration tested came out within +-2 % of the market mean. Storage
% headroom should only appear in the shoulder season, when the load falls
% to 3-5 kW -- see SHOULDER-SEASON note at startDate below.
T_room_ref = 20.2;
T_tank_ref = 45;                      % ignored, tank tracking weight is 0
refVec     = [T_room_ref, T_tank_ref];

weatherData = readtable('DATA/weather_langenhagen_2025.csv');
weatherData.timestamp = datetime(weatherData.timestamp, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');

% SHOULDER SEASON. The January window (2025-01-15, 15 days) is the
% design-season case: load 6-9 kW, emitter near fully open, no valve
% authority to spare and therefore no accessible storage. To test whether
% price-responsive storage works at all in this building, run a shoulder
% window where the load falls to 3-5 kW and the valve has slack:
%
%   startDate = datetime('2025-03-15');   % spring shoulder
%   startDate = datetime('2025-10-15');   % autumn shoulder
%
% Expect fewer, longer compressor cycles there but MORE below-floor
% pulsing, since 3-5 kW sits near the 4 kW modulation limit.
startDate = datetime('2025-03-15');   % <-- set desired simulation start date
simulationDays = 15;
nSamples = simulationDays*24*4;

startIdx = find(weatherData.timestamp >= startDate, 1);
if isempty(startIdx)
    error('init:startDate', ...
        'startDate %s is after the end of the weather data (%s).', ...
        datestr(startDate), datestr(weatherData.timestamp(end)));
end
if startIdx + nSamples - 1 > height(weatherData)
    availDays = floor((height(weatherData) - startIdx + 1) / 96);
    error('init:tooLong', ...
        ['Only %d full days of weather data exist after %s, but ' ...
         'simulationDays = %d was requested.'], ...
        availDays, datestr(startDate), simulationDays);
end
idxRange = startIdx:(startIdx+nSamples-1);
weatherData = weatherData(idxRange, :);

time_sec = (0:(height(weatherData)-1))' * 900;
weather_ts = timeseries(weatherData.T_out_C, time_sec);
weather_ts.Name = 'Real_Weather_Data';

plant_d0 = getAdaptivePlant(weatherData.T_out_C(1), heating_curve(weatherData.T_out_C(1)), ...
                            Ts, Req, C_air, C_tank, H_rad, TinIC, T_trv_set);

% --- Horizons ---
% p = 96 steps x 900 s = 24 h prediction, m = 96 free control moves.
%
% WHY NOT p = 48, m = 5 (the previous setting). Two hard structural
% limits, both of which made load shifting impossible regardless of how
% the price signal was weighted:
%
%   CONTROL HORIZON. With m = 5 the optimiser gets five free moves --
%   75 minutes -- and the command is then FROZEN for the remaining 43
%   steps, nearly 11 hours. Shifting load requires a profile shaped like
%   "run hard for three hours, off for four, run hard again". That shape
%   simply cannot be represented with five decision variables, so the
%   controller was never choosing not to shift; it was unable to.
%
%   PREDICTION HORIZON. Day-ahead prices cycle over 24 h. A 12 h horizon
%   means that at 18:00 the controller cannot see the overnight trough,
%   so it can never decide to coast through an evening peak and recharge
%   afterwards. 24 h is the minimum that covers one full price cycle.
%
% 96 QP variables plus slack is trivial for the KWIK solver at a 15-minute
% control interval.
p = 96; m = 96;
mpcobj = mpc(plant_d0, Ts, p, m);

% --- Nominal operating point: THE ORIGIN, not [20; 40] ---
% The plant equations in getAdaptivePlant are purely linear in the states
% and inputs -- there is no constant term anywhere:
%
%   C_air *dT_room/dt = h*(T_tank - T_room) - UA*(T_room - T_out)
%   C_tank*dT_tank/dt = Qmax*u          - h*(T_tank - T_room)
%
% An adaptive MPC predicts dx = A*(x - X) + B*(u - U) + DX. Declaring
% X = [20; 40], U = [0; T_out] with DX = [0; 0] asserts that the state is
% stationary there. It is not: substituting those values gives
% dT_tank/dt = -312*(40-20)/2.093e6 = -2.98e-3 K/s = -10.7 K/h. The
% controller therefore believed a 40 C tank would hold with the pump off,
% switched off, was surprised when the tank collapsed, and swung back to
% full power. That systematic offset was a major contributor to the
% cycling. For a linear model with no affine term the only consistent
% nominal point is zero.
mpcobj.Model.Nominal.U  = [0; 0];
mpcobj.Model.Nominal.Y  = [0; 0];
mpcobj.Model.Nominal.X  = [0; 0];
mpcobj.Model.Nominal.DX = [0; 0];

mpcobj.MV(1).Min = 0;
mpcobj.MV(1).Max = 1;

% --- Room temperature bounds (OV 1) ---
% The upper bound is what stops the compressor's ~4 kW minimum modulation
% floor from being dumped into the room during mild weather. Without it
% nothing in the cost function penalises a 28 C room in a 20 C setpoint.
%
% HARD vs SOFT: MaxECR = 0 makes the bound hard. With the buffer tank in
% place the surplus now has somewhere to go, so this is far less likely to
% go infeasible than it was pre-tank. Set T_room_max_ECR to a large
% positive number (e.g. 1e5) for a heavily-weighted soft bound instead.
%
% NOTE ON ECR DIRECTION: in the MPC toolbox a LARGER ECR means the
% constraint is allowed to relax MORE (softer); MaxECR = 0 is hard. The
% old comment here had this backwards.
%
% With the TRVs modelled the room physically cannot exceed ~21 C, so the
% 24 C ceiling is now unreachable in normal operation. It is kept as a
% safety net but made SOFT: a hard bound that the solver cannot satisfy
% during the initial transient makes the QP infeasible, and an infeasible
% QP produces exactly the erratic command jumps we are trying to remove.
T_room_min     = 19.5;
T_room_max     = 24;
T_room_max_ECR = 1;      % 0 = hard constraint; >0 = soft with that ECR

mpcobj.OV(1).Min    = T_room_min;
mpcobj.OV(1).Max    = T_room_max;
mpcobj.OV(1).MinECR = 0.01;              % firm soft bound -- see Weights below
mpcobj.OV(1).MaxECR = T_room_max_ECR;

% --- Buffer tank bounds (OV 2) ---
% The tank is NOT tracked to a setpoint -- it is a free storage state the
% optimiser may move within these limits. That freedom is exactly what
% enables load shifting: run the tank hot when energy is cheap, coast on
% it when it is not.
%
% Both bounds are SOFT (ECR > 0). A hard tank bound would make the QP
% infeasible during any cold snap where the machine simply cannot keep up,
% and a violated tank temperature is a performance issue, not a safety one.
T_tank_min = 25;         % below this the emitter cannot deliver useful heat
T_tank_max = 55;         % radiator design supply temperature

mpcobj.OV(2).Min    = T_tank_min;
mpcobj.OV(2).Max    = T_tank_max;
mpcobj.OV(2).MinECR = 1;
mpcobj.OV(2).MaxECR = 1;

if T_room_max_ECR == 0
    boundType = 'HARD';
else
    boundType = 'soft';
end
fprintf('Room bounds: [%.1f, %.1f] C  (upper bound %s).\n', ...
    T_room_min, T_room_max, boundType);
fprintf('Tank bounds: [%.1f, %.1f] C  (both soft).\n', T_tank_min, T_tank_max);
fprintf('TRV: fully open at %.1f C, shut at %.1f C (max %.0f W/K).\n', ...
    T_trv_set - 1, T_trv_set, H_rad);
fprintf('Room reference %.2f C (inside the %.1f-%.1f C throttling band).\n', ...
    T_room_ref, T_trv_set - 1, T_trv_set);

% --- Weights ---
% BOTH outputs get weight 0. Neither the room nor the tank is tracked to a
% setpoint; both are free states the optimiser may move inside their
% bounds. The objective is therefore cost subject to comfort, which is the
% correct economic formulation, rather than setpoint tracking with a cost
% term bolted on.
%
% MinECR stays at 0.01 (a firm soft bound): in the MPC Toolbox a SMALLER
% ECR means the constraint is relaxed LESS.
%
% WHY THE ROOM WEIGHT HAD TO GO. With OV(1) weight 1.0 the controller was
% paid to hold the room at exactly 20 C. The TRVs only shut at 21 C, so at
% 20 C the emitter is still ~312 W/K open and at 20.5 C still ~156 W/K --
% the tank drained roughly 4 kW into the room continuously and could never
% hold a charge. Every run, at every price weight, topped out at a room
% temperature of 20.46 C and a tank of ~46.9 C for exactly this reason:
% drifting UP towards 21 C, which is the drift that closes the valve and
% lets the tank charge, was penalised harder than the price signal
% rewarded it. The price term was fighting the tracking term and losing.
%
% WHAT THIS UNLOCKS. Letting the room float across its 19-21 C band (21 C
% being where the TRVs cap it anyway) makes the building fabric itself
% available as storage:
%   buffer tank            ~17 kWh thermal (30 K x 0.581 kWh/K)
%   building 19 -> 21 C    ~41 kWh thermal (2 K x 20.7 kWh/K)
% i.e. roughly three times the store, reached without touching the valves
% -- it uses the two degrees the residents already tolerate.
%
% WHY THE ROOM WEIGHT IS SMALL BUT NOT ZERO. Setting it to zero looks like
% the clean economic formulation -- cost subject to comfort -- but it
% fails in practice: with nothing pulling the room away from its bound,
% the cheapest PREDICTED trajectory sits exactly ON the 19 C limit, so any
% plant/model mismatch lands roughly half the time on the wrong side of
% it. A run with OV = [0, 0] spent 47 hours below 19 C for exactly this
% reason. A constraint you sit on is a constraint you violate.
%
% 0.3 holds the operating point up inside the 20-21 C throttling band
% while staying below the price term (lambda 0.2 gives an effective weight
% of 0.12-0.49), so price can still push the room down towards 20 C during
% peaks and let it drift up towards 21 C when power is cheap. At 0.1 the
% price term outranked the anchor by 4-11x and the controller simply rode
% the lower bound at 19 C, where the valve is clamped fully open and no
% storage is possible. At 1.0 the anchor outranked price by 5x and the
% controller ignored cost entirely.
%
% The tank keeps weight 0: it is a means, not an end, and tracking it to a
% setpoint would directly fight the charge/discharge behaviour that makes
% storage useful.
mpcobj.Weights.OV     = [0.3, 0];
mpcobj.Weights.MVRate = 0.1;

% --- Manipulated-variable weight: MUST be time-varying from the start ---
% This is the term that makes the controller price-aware. The MV target
% defaults to the nominal input (zero), so a weight w on the MV adds
% w*u^2 to the cost -- a penalty for running the compressor. Feeding a
% weight proportional to the electricity price therefore makes running
% expensive when power is expensive and cheap when it is cheap.
%
% It is declared here as a p-by-1 COLUMN (one row per prediction step)
% rather than a scalar. The MPC block refuses to accept time-varying
% weights at run time unless the controller object was built with
% time-varying weights, so a scalar here would silently lock out the
% whole mechanism.
%
% MVRate stays a scalar: only the MV weight varies over the horizon.
mpcobj.Weights.ManipulatedVariables = repmat(PRICE_WEIGHT, p, 1);

% --- Real electricity price: Tibber 2025, 15-min, EUR/kWh (German decimals) ---
priceRaw   = readcell('DATA/electricity_prices_2025.csv');
priceStr   = string(priceRaw(2:end, 3));                % 3rd col = "Tibber 2025"
price_kWh  = str2double(replace(priceStr, ",", "."));   % comma decimal -> dot

% Align the price series to startDate by PARSING its own timestamps rather
% than computing an index arithmetically from 2025-01-01. German market
% data is local time and includes DST transitions, so after 2025-03-30 a
% computed index drifts by 4 samples (1 hour) against the weather series,
% which is sliced by real timestamp. Parsing keeps the two in lockstep.
%
% readcell may hand back the "Datum von" column either as text or as
% already-parsed datetime objects depending on release and locale, so
% handle both instead of assuming one.
priceTime = parsePriceTime(priceRaw(2:end, 1));

priceStartIdx = find(priceTime >= startDate, 1);
if isempty(priceStartIdx)
    error('init:priceStart', ...
        'startDate %s is after the end of the price data (%s).', ...
        datestr(startDate), datestr(priceTime(end)));
end
if priceStartIdx + nSamples - 1 > numel(price_kWh)
    error('init:priceTooShort', ...
        ['Only %d price samples exist after %s, but %d are needed for ' ...
         'simulationDays = %d.'], ...
        numel(price_kWh) - priceStartIdx + 1, datestr(startDate), ...
        nSamples, simulationDays);
end

priceSlice = priceStartIdx:(priceStartIdx+nSamples-1);
price_kWh  = price_kWh(priceSlice);

% Sanity check: the two series must describe the same wall-clock window.
skew = abs(seconds(priceTime(priceStartIdx) - weatherData.timestamp(1)));
if skew > 900
    warning('init:priceWeatherSkew', ...
        ['Price series starts %s but weather starts %s (%.0f s apart). ' ...
         'Cost figures will be attributed to the wrong hours.'], ...
        datestr(priceTime(priceStartIdx)), ...
        datestr(weatherData.timestamp(1)), skew);
end

price_time = (0:(numel(price_kWh)-1))' * 900;           % same 15-min grid, aligned to startDate
price_ts   = timeseries(price_kWh, price_time);
price_ts.Name = 'Tibber_2025_EUR_per_kWh';

% --- Price forecast fed to the MPC as a time-varying MV weight ---
% WHY A WEIGHT AND NOT A COST TERM. The MPC Toolbox objective is purely
% quadratic, so an exact linear energy cost (price * Pel * dt) cannot be
% expressed. Weighting the MV penalty by price is the standard surrogate:
% the controller still pays more to run during expensive hours and less
% during cheap ones, which is what drives the load shifting. It is an
% approximation of the true cost, not the true cost, and the thesis
% should say so.
%
% WHY THE WHOLE HORIZON AND NOT JUST THE CURRENT PRICE. Load shifting is
% impossible without foresight. A controller that only knows this
% interval's price can refuse to run when power is expensive, but it can
% never decide to charge the tank NOW because power gets expensive in
% three hours. Row i of wuFcst holds the weights for steps i..i+p-1, so
% the controller sees a full 12 h ahead (p = 48 at Ts = 900 s), which is
% roughly the useful range of day-ahead prices anyway.
%
% NORMALISATION. Weights are divided by the mean price over the window,
% so PRICE_WEIGHT keeps the same meaning regardless of the absolute price
% level and runs on different dates stay comparable. Note the mean
% component of the weight acts as a uniform penalty on running at all,
% which biases the controller towards under-heating -- that is the
% unavoidable side effect of a quadratic surrogate, and the reason
% PRICE_WEIGHT needs sweeping rather than guessing.
%
% The tail is padded by holding the last price, so the final p intervals
% of the run do not read past the end of the data.
priceRef = mean(price_kWh, 'omitnan');
wu       = PRICE_WEIGHT * (price_kWh / priceRef);
wu(~isfinite(wu)) = PRICE_WEIGHT;
wuPad    = [wu; repmat(wu(end), p, 1)];

wuFcst = zeros(nSamples, p);
for i = 1:nSamples
    wuFcst(i, :) = wuPad(i:(i+p-1));
end

% From Workspace needs [nSamples x p x 1] to emit a p-by-1 matrix signal,
% which is the shape the u.wt inport expects (Nmv = 1 column, p rows).
u_wt_ts = timeseries(reshape(wuFcst, nSamples, p, 1), price_time);
u_wt_ts.Name = 'MPC_MV_weight_from_price';
assignin('base', 'u_wt_ts', u_wt_ts);

fprintf('Price weight lambda = %.3f, forecast horizon %d steps (%.1f h).\n', ...
    PRICE_WEIGHT, p, p*Ts/3600);
fprintf('MV weight range over run: %.3f to %.3f.\n', min(wu), max(wu));

% Scalar 'cost' kept so the in-model Cost Gain block still resolves; set to
% the MEAN real price. The true time-varying series is price_ts, which
% analyze_run.m uses for exact per-interval cost. Units: EUR per Joule.
cost = mean(price_kWh, 'omitnan') / 3.6e6;
assignin('base', 'cost', cost);
assignin('base', 'price_ts', price_ts);
fprintf('Loaded %d price samples, mean %.4f EUR/kWh.\n', numel(price_kWh), mean(price_kWh,'omitnan'));

% Auto-match run length to the available weather data (instead of a
% hardcoded StopTime). loadmodel is safe here: plant_d0/mpcobj already exist.
if ~bdIsLoaded('HouseHeatingSystem'), load_system('HouseHeatingSystem'); end
simulationTime = simulationDays * 24 * 3600;

set_param('HouseHeatingSystem', 'StopTime', num2str(simulationTime));

fprintf('Simulation will run for %d days.\n', simulationDays);


% ------------------------------------------------------------------
% Local functions (must stay at the end of the script file)
% ------------------------------------------------------------------

function t = parsePriceTime(col)
%PARSEPRICETIME Convert the "Datum von" column to datetime, robustly.
% readcell returns this column either as text ("01.01.2025 00:00") or as
% already-parsed datetime values, depending on MATLAB release and system
% locale. Handle both, and try several text layouts before giving up.

% Case 1: readcell already parsed them.
if ~isempty(col) && isdatetime(col{1})
    t = reshape([col{:}], [], 1);
    return
end

% Case 2: text. Try the layouts this file has been seen to use.
s = string(col(:));
fmts = {'dd.MM.yyyy HH:mm', 'dd.MM.yyyy HH:mm:ss', ...
        'yyyy-MM-dd HH:mm',  'yyyy-MM-dd HH:mm:ss', ...
        'dd/MM/yyyy HH:mm'};

for k = 1:numel(fmts)
    try
        t = datetime(s, 'InputFormat', fmts{k});
        if ~any(isnat(t))
            return
        end
    catch
        % Wrong layout -- try the next one.
    end
end

% Last resort: let MATLAB guess.
try
    t = datetime(s);
    if ~any(isnat(t))
        return
    end
catch
end

error('init:priceTimeParse', ...
    ['Could not parse the price file''s "Datum von" column. First value ' ...
     'is: %s (class %s). Add its layout to the fmts list in ' ...
     'parsePriceTime inside init_adaptive_mpc.m.'], ...
    s(1), class(col{1}));
end
