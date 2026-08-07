function results = analyze_run()
%ANALYZE_RUN  Run the simulation, count heat-pump cycles, and measure
% electricity + cost using the real Tibber prices.
%
% Requires the workspace prepared by init_adaptive_mpc.m (weatherData +
% price_ts). It logs ONLY the 0-1 heater command ('signal'); electricity
% is recomputed exactly from it with your own hp_heater_physics, so no
% model rewiring and no extra sensors are needed.
%
% A "cycle" here = one compressor START (an off->on transition), the
% standard short-cycling metric. Also reported per day and per hour.
%
% Run order:  init_adaptive_mpc  ->  analyze_run

mdl = 'HouseHeatingSystem';
if ~bdIsLoaded(mdl), load_system(mdl); end

% Guard: a scope with a corrupt manual Y-limit (Ymin >= Ymax) aborts sim.
% Force every scope to auto-scale so it can't block the run.
for b = find_system(mdl,'BlockType','Scope')'
    try, c = get_param(b{1},'ScopeConfiguration'); c.AxesScaling = 'Auto'; end %#ok<TRYNC>
end

% --- pull prepared data from the base workspace ---
if evalin('base','~exist(''price_ts'',''var'') || ~exist(''weatherData'',''var'')')
    error('analyze_run:setup', 'price_ts / weatherData missing -- run init_adaptive_mpc first.');
end
price_ts    = evalin('base','price_ts');
weatherData = evalin('base','weatherData');
T_out_all   = weatherData.T_out_C;
w_time      = (0:numel(T_out_all)-1)' * 900;

% --- turn on logging for the command signal named 'signal' ---
set_param(mdl, 'SignalLogging','on', 'SignalLoggingName','logsout');
Ls = find_system(mdl, 'FindAll','on', 'type','line');
found = false;
for L = Ls'
    if strcmp(get_param(L,'Name'), 'signal')
        set_param(L, 'DataLogging','on'); found = true;
    end
end
if ~found
    error('analyze_run:signal', ...
        ['Could not find a line named ''signal'' (MPC command). Name the ' ...
         'MPC->Heater line ''signal'' in the model and re-run.']);
end

fprintf('Running simulation (this can take a while for long runs)...\n');
out  = sim(mdl);
sig  = out.logsout.get('signal').Values;   % 0-1 command as a timeseries
u    = double(sig.Data(:));
tu   = sig.Time(:);

% --- align outdoor temp + price onto the command time base ---
Tout = interp1(w_time,        T_out_all,      tu, 'previous', 'extrap');
pk   = interp1(price_ts.Time,  price_ts.Data, tu, 'previous', 'extrap');   % EUR/kWh

% --- recompute per-sample electricity via the real HP physics ---
Elec = zeros(size(u));                      % [W]
for k = 1:numel(u)
    Tsup = heating_curve(Tout(k));
    [~, Elec(k)] = hp_heater_physics(u(k), Tout(k), Tsup);
end

% --- cycle count: compressor starts = off->on crossings of U_OFF ---
U_OFF  = 0.05;
on     = u >= U_OFF;
starts = sum(on(2:end) & ~on(1:end-1));     % rising edges
days   = max((tu(end) - tu(1)) / 86400, eps);

% --- energy + cost (trapezoid over time; W*s -> kWh via /3.6e6) ---
kWh        = trapz(tu, Elec)        / 3.6e6;
eur        = trapz(tu, Elec .* pk)  / 3.6e6;         % integral of P*price
avg_paid   = eur / max(kWh, eps);
mkt_mean   = mean(pk, 'omitnan');

% --- report ---
fprintf('\n===== RUN SUMMARY (%.1f days) =====\n', days);
fprintf('HP compressor starts (cycles) : %d\n', starts);
fprintf('   -> %.1f cycles/day   (%.2f cycles/hour)\n', starts/days, starts/days/24);
fprintf('Electricity consumed          : %.1f kWh   (%.1f kWh/day)\n', kWh, kWh/days);
fprintf('Electricity cost (Tibber real): %.2f EUR\n', eur);
fprintf('Average price paid            : %.4f EUR/kWh  (market mean %.4f)\n', avg_paid, mkt_mean);
fprintf('=====================================\n');
fprintf('(avg paid ~= market mean is expected: the controller is not yet\n');
fprintf(' price-aware, so it does no load-shifting. That gap is the headroom.)\n');

results = struct('days',days, 'cycles',starts, 'cycles_per_day',starts/days, ...
                 'kWh',kWh, 'cost_eur',eur, 'avg_price_eur_kWh',avg_paid, ...
                 'market_mean_eur_kWh',mkt_mean);
end
