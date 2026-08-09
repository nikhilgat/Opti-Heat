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
% Also opportunistically log the room temperature if the line carrying it
% has one of the recognised names, so plot_run can draw the temperature
% trace. Not fatal if absent -- the command/price plots still work.
ROOM_LINE_NAMES = {'Troom','T_room','Room','room','Troom_C'};

set_param(mdl, 'SignalLogging','on', 'SignalLoggingName','logsout');
Ls = find_system(mdl, 'FindAll','on', 'type','line');
found = false;
roomLineName = '';
for L = Ls'
    nm = get_param(L,'Name');
    if strcmp(nm, 'signal')
        found = tryEnableLogging(L) || found;
    elseif any(strcmp(nm, ROOM_LINE_NAMES))
        if tryEnableLogging(L)
            roomLineName = nm;
        end
    end
end
if ~found
    error('analyze_run:signal', ...
        ['Could not find a loggable line named ''signal'' (MPC command). Name the ' ...
         'MPC->Heater line ''signal'' in the model and re-run. Note that Simscape ' ...
         'physical connection lines cannot be logged -- the line must be a ' ...
         'Simulink signal line.']);
end
if isempty(roomLineName)
    warning('analyze_run:noRoomSignal', ...
        ['No loggable room-temperature line found (looked for: %s). The temperature ' ...
         'plot will be skipped. Name the Simulink-side room-temperature line ' ...
         '''Troom'' in the model to enable it -- it must be downstream of the ' ...
         'PS-Simulink converter, not a Simscape physical line.'], ...
        strjoin(ROOM_LINE_NAMES, ', '));
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

% --- plots: x axis in days (or hours for short runs), y in degrees C ---
plot_run(tu, Tout, u, pk, out, roomLineName, days);

end


function ok = tryEnableLogging(L)
%TRYENABLELOGGING Turn on DataLogging for a line handle, tolerating lines
% that do not support it. Simscape physical connection lines (and some
% branch segments) have no 'DataLogging' parameter, so a bare set_param
% aborts the whole run. Returns true only if logging was actually enabled.
ok = false;
try
    set_param(L, 'DataLogging', 'on');
    ok = true;
catch
    % Not a loggable Simulink signal line -- skip it silently.
end
end


function plot_run(tu, Tout, u, pk, out, roomLineName, days)
%PLOT_RUN Time-series overview with a readable time axis.
% Seconds on the x axis are unreadable past a few hours, so the axis is
% rescaled to hours for runs under 2 days and days beyond that.

if days < 2
    tPlot  = tu / 3600;
    tLabel = 'Time [h]';
else
    tPlot  = tu / 86400;
    tLabel = 'Time [days]';
end

% Room temperature, if it was logged.
Troom = [];
if ~isempty(roomLineName)
    try
        rv = out.logsout.get(roomLineName).Values;
        rt = rv.Time(:);
        rd = double(rv.Data(:));
        % Variable-step / zero-crossing solvers can emit duplicate time
        % stamps, which interp1 rejects. Keep the last sample per instant.
        [rt, iu] = unique(rt, 'last');
        rd = rd(iu);
        Troom = interp1(rt, rd, tu, 'linear', 'extrap');
    catch ME
        warning('plot_run:roomFetch', ...
            'Room line ''%s'' was marked for logging but could not be read (%s).', ...
            roomLineName, ME.message);
    end
end

figure('Name','Adaptive MPC run','Color','w');

% --- Panel 1: temperatures ---
ax1 = subplot(3,1,1);
plot(tPlot, Tout, 'LineWidth', 1.0, 'DisplayName','Environment'); hold on
if ~isempty(Troom)
    plot(tPlot, Troom, 'LineWidth', 1.0, 'DisplayName','Room');
end
hold off
% char(176) is the degree sign, written this way so the .m file stays
% pure-ASCII and does not depend on the editor's encoding.
degC = [char(176) 'C'];
ylabel(ax1, ['Temperature [' degC ']']);
title(ax1, 'Temperature');
legend(ax1, 'Location','best'); grid(ax1,'on');
ytickformat(ax1, ['%g' degC]);

% --- Panel 2: MPC command ---
ax2 = subplot(3,1,2);
plot(tPlot, u, 'LineWidth', 1.0);
ylabel(ax2, 'HP command [-]');
title(ax2, 'Modulation (0-1)');
ylim(ax2, [-0.05 1.05]); grid(ax2,'on');

% --- Panel 3: electricity price ---
ax3 = subplot(3,1,3);
plot(tPlot, pk, 'LineWidth', 1.0);
ylabel(ax3, 'Price [EUR/kWh]');
xlabel(ax3, tLabel);
title(ax3, 'Day-ahead price (Tibber)');
grid(ax3,'on');

linkaxes([ax1 ax2 ax3], 'x');
xlim(ax1, [tPlot(1) tPlot(end)]);
end

