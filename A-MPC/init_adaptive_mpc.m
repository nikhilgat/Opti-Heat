%% Run this BEFORE opening/updating HouseHeatingSystem.slx
% The Adaptive MPC Controller block's InitFcn resolves plant_d0 and
% mpcobj from the base workspace at load time -- they must exist before
% Simulink parses the block mask.

Ts = 900;

% --- Virchowstr. 6 lumped RC for the MPC INTERNAL model ---
% UA = 366 W/K  (documented design load 10968 W / 30 K)
% C  = 7.46e7 J/K (72 Wh/m2K x 287.92 m2).  See virchowstr6_building.m.
% Kept 1R1C on purpose: the controller model is a reduced view of the
% richer multi-mass Simscape plant (patch_plant_to_virchowstr6.m).
Req   = 1/366;
C_air = 7.46e7;
TinIC = 20;

weatherData = readtable('DATA/weather_langenhagen_2025.csv');
weatherData.timestamp = datetime(weatherData.timestamp, 'InputFormat', 'yyyy-MM-dd HH:mm:ss');

startDate = datetime('2025-07-01');   % <-- set desired simulation start date
simulationDays = 10;
nSamples = simulationDays*24*4;

startIdx = find(weatherData.timestamp >= startDate, 1);
idxRange = startIdx:(startIdx+nSamples-1);
weatherData = weatherData(idxRange, :);

time_sec = (0:(height(weatherData)-1))' * 900;
weather_ts = timeseries(weatherData.T_out_C, time_sec);
weather_ts.Name = 'Real_Weather_Data';

plant_d0 = getAdaptivePlant(weatherData.T_out_C(1), heating_curve(weatherData.T_out_C(1)), Ts, Req, C_air);

p = 48; m = 5;
mpcobj = mpc(plant_d0, Ts, p, m);
mpcobj.Model.Nominal.U = [0, weatherData.T_out_C(1)];
mpcobj.Model.Nominal.Y = TinIC;
mpcobj.Model.Nominal.X = TinIC;
mpcobj.MV(1).Min = 0;
mpcobj.MV(1).Max = 1;

% --- Room temperature bounds (OV constraint) ---
% The upper bound is what stops the compressor's ~4 kW minimum modulation
% floor from being dumped into the room during mild weather. Without it
% nothing in the cost function penalises a 28 C room in a 20 C setpoint.
%
% HARD vs SOFT: MaxECR = 0 makes the bound hard. Be aware this is
% physically unachievable in mild weather until the buffer tank exists --
% at T_out = 14 C the building needs ~2.2 kW but the machine cannot go
% below ~4.0 kW, so no admissible input satisfies the bound and the QP
% goes infeasible. MPC Toolbox then falls back to the least-violating
% solution and warns. Set T_room_max_ECR to a large positive number
% (e.g. 1e5) to make it a heavily-weighted soft bound instead.
T_room_min     = 19;
T_room_max     = 24;
T_room_max_ECR = 0;      % 0 = hard constraint; >0 = soft with that ECR

mpcobj.OV(1).Min    = T_room_min;
mpcobj.OV(1).Max    = T_room_max;
mpcobj.OV(1).MinECR = 1;                 % lower bound stays soft (comfort)
mpcobj.OV(1).MaxECR = T_room_max_ECR;

if T_room_max_ECR == 0
    boundType = 'HARD';
else
    boundType = 'soft';
end
fprintf('Room bounds: [%.1f, %.1f] C  (upper bound %s).\n', ...
    T_room_min, T_room_max, boundType);
mpcobj.Weights.MVRate = 0.1;
mpcobj.Weights.OV = 1.0;

% --- Real electricity price: Tibber 2025, 15-min, EUR/kWh (German decimals) ---
priceRaw   = readcell('DATA/electricity_prices_2025.csv');
priceStr   = string(priceRaw(2:end, 3));                % 3rd col = "Tibber 2025"
price_kWh  = str2double(replace(priceStr, ",", "."));   % comma decimal -> dot

priceStartIdx = round(seconds(startDate - datetime(2025,1,1))/900) + 1;
price_kWh = price_kWh(priceStartIdx:(priceStartIdx+nSamples-1));

price_time = (0:(numel(price_kWh)-1))' * 900;           % same 15-min grid, aligned to startDate
price_ts   = timeseries(price_kWh, price_time);
price_ts.Name = 'Tibber_2025_EUR_per_kWh';

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
