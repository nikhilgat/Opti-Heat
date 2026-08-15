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

% --- results folder: RESULTS/run_YYYYmmdd_HHMMSS ---
% Everything printed to the command window and every figure produced is
% captured here, so a run can be reconstructed and debugged later without
% re-running it.
runStamp = datestr(now, 'yyyymmdd_HHMMSS');
runDir   = fullfile(fileparts(fileparts(mfilename('fullpath'))), ...
                    'RESULTS', ['run_' runStamp]);
if ~exist(runDir, 'dir'), mkdir(runDir); end

diaryFile = fullfile(runDir, 'console.log');
diary(diaryFile);
diary on
cleanupDiary = onCleanup(@() diary('off'));   % closes even if we error out

fprintf('===== analyze_run %s =====\n', runStamp);
fprintf('Results directory: %s\n\n', runDir);

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

% --- record the run configuration in the log, for later comparison ---
fprintf('--- Run configuration ---\n');
logBaseVar('startDate');
logBaseVar('simulationDays');
logBaseVar('Req');
logBaseVar('C_air');
logBaseVar('T_room_min');
logBaseVar('T_room_max');
logBaseVar('T_room_max_ECR');
try
    fprintf('  Weather window   : %s  ->  %s\n', ...
        datestr(weatherData.timestamp(1)), datestr(weatherData.timestamp(end)));
catch
end
fprintf('  StopTime         : %s s\n', get_param(mdl,'StopTime'));
fprintf('\n');

% --- turn on logging for the command signal named 'signal' ---
% Also opportunistically log the room temperature if the line carrying it
% has one of the recognised names, so plot_run can draw the temperature
% trace. Not fatal if absent -- the command/price plots still work.
ROOM_LINE_NAMES = {'Troom','T_room','Room','room','Troom_C'};
TANK_LINE_NAMES = {'Ttank','T_tank','Tank','tank','Ttank_C'};

set_param(mdl, 'SignalLogging','on', 'SignalLoggingName','logsout');
Ls = find_system(mdl, 'FindAll','on', 'LookUnderMasks','all', ...
                      'FollowLinks','on', 'type','line');
found = false;
roomLineName = '';
tankLineName = '';
for L = Ls'
    nm = get_param(L,'Name');
    if strcmp(nm, 'signal')
        found = tryEnableLogging(L, 'signal') || found;
    elseif any(strcmp(nm, ROOM_LINE_NAMES))
        if tryEnableLogging(L, nm)
            roomLineName = nm;
        end
    elseif any(strcmp(nm, TANK_LINE_NAMES))
        if tryEnableLogging(L, nm)
            tankLineName = nm;
        end
    end
end

% Fallback: a 'To Workspace' block named u_log on the MPC command line.
% Line names are easy to lose when rewiring, and a named PORT looks
% identical to a named LINE on the canvas, so this gives a path that does
% not depend on naming at all.
useToWorkspace = false;
if ~found
    twBlocks = find_system(mdl, 'LookUnderMasks','all', 'FollowLinks','on', ...
                                'BlockType','ToWorkspace');
    for b = 1:numel(twBlocks)
        if strcmp(get_param(twBlocks{b}, 'VariableName'), 'u_log')
            useToWorkspace = true;
            break
        end
    end
end

if ~found && ~useToWorkspace
    warning('analyze_run:noLoggingConfigured', ...
        ['Could not mark the MPC command line for logging, and no ''u_log'' ' ...
         'To Workspace block was found. Running anyway -- if this fails, ' ...
         'add a To Workspace block on the MPC ''mv'' output with Variable ' ...
         'name ''u_log'' and Save format ''Timeseries''.']);
end
if isempty(roomLineName)
    roomLineName = 'Troom';   % still lets the Troom_log To Workspace path work
end
if isempty(tankLineName)
    tankLineName = 'Ttank';   % still lets the Ttank_log To Workspace path work
end

fprintf('Running simulation (this can take a while for long runs)...\n');
% Force a single SimulationOutput object. Models inherited from older
% MathWorks demos often have this off, in which case To Workspace
% variables and logsout are dumped into the BASE workspace instead of
% being returned in 'out' -- which looks exactly like "nothing was
% logged". Setting it here makes retrieval deterministic.
prevReturnOutputs = get_param(mdl, 'ReturnWorkspaceOutputs');
set_param(mdl, 'ReturnWorkspaceOutputs', 'on');
restoreCfg = onCleanup(@() set_param(mdl, 'ReturnWorkspaceOutputs', prevReturnOutputs));

out  = sim(mdl);

% --- retrieve the command signal ---
% To Workspace blocks are checked FIRST: signal logging via set_param has
% proven unreliable across releases (DataLogging moved from lines to
% ports, and logsout is sometimes never created at all), whereas a To
% Workspace block always lands its variable in the SimulationOutput.
sig = fetchToWorkspace(out, 'u_log');
if isempty(sig)
    sig = fetchLogged(out, 'signal');
end
if isempty(sig)
    avail = listLogged(out);
    error('analyze_run:noSignalData', ...
        ['The simulation ran but no command-signal data came back.\n' ...
         'Signals in logsout: %s\n\n' ...
         'MOST RELIABLE FIX -- add To Workspace blocks (Simulink > Sinks),\n' ...
         'each with Save format = ''Timeseries'':\n' ...
         '   u_log     on the MPC ''mv'' output (the 0-1 command)\n' ...
         '   Troom_log on the room temperature signal      (optional)\n' ...
         '   Ttank_log on the buffer tank temperature      (optional)\n\n' ...
         'Alternative: right-click the command wire > Log Selected Signals.'], ...
        avail);
end

u    = double(sig.Data(:));
tu   = sig.Time(:);

% --- Put the command on a uniform 15-min control grid ---
% With a variable-step solver the logged command comes back at solver
% steps, not control steps. Counting compressor starts on that grid would
% count solver activity, and summing energy on it needs trapezoids. The
% command is piecewise constant over Ts anyway, so resampling with
% 'previous' loses nothing and makes every downstream sum exact.
TS_CTRL = 900;
[tu, iuq] = unique(tu, 'last');
u = u(iuq);
tc = (tu(1):TS_CTRL:tu(end))';
if numel(tc) > 1
    u  = interp1(tu, u, tc, 'previous', 'extrap');
    tu = tc;
end

% --- align outdoor temp + price onto the command time base ---
Tout = interp1(w_time,        T_out_all,      tu, 'previous', 'extrap');
pk   = interp1(price_ts.Time,  price_ts.Data, tu, 'previous', 'extrap');   % EUR/kWh

% --- recompute per-sample heat, electricity and duty via the real HP physics ---
Elec = zeros(size(u));                      % [W]
Heat = zeros(size(u));                      % [W]
duty = zeros(size(u));                      % [-] fraction of interval running
for k = 1:numel(u)
    Tsup = heating_curve(Tout(k));
    [Heat(k), Elec(k), duty(k)] = hp_heater_physics(u(k), Tout(k), Tsup);
end

days = max((tu(end) - tu(1)) / 86400, eps);

% --- cycle count: real compressor starts, derived from DUTY ---
% The old metric counted rising edges of the MPC command through 0.05.
% That measured the controller changing its mind, not the machine: under
% the previous physics law the compressor delivered its 4 kW minimum even
% at u = 0 and therefore never stopped at all.
%
% With the duty-cycle model the compressor state over each control
% interval is unambiguous:
%   duty == 0        -> off for the whole interval, no start
%   0 < duty < 1     -> demand is below the ~4 kW modulation floor, so the
%                       machine switches on and off once inside this
%                       interval: exactly one start
%   duty == 1        -> running continuously; a start only if the previous
%                       interval was fully off
DUTY_OFF = 1e-6;
starts   = 0;
for k = 1:numel(duty)
    if duty(k) <= DUTY_OFF
        continue
    elseif duty(k) < 1 - DUTY_OFF
        starts = starts + 1;                % one on/off pulse in this interval
    elseif k == 1 || duty(k-1) <= DUTY_OFF
        starts = starts + 1;                % transition from fully off
    end
end

% Mean run length: the start count alone is misleading, because many very
% short runs and a few long ones give the same number. Short runs are the
% damaging kind, so report the average ON duration and the ON fraction
% too. A high start count with multi-hour runs is normal modulation; the
% same count with 5-minute runs is genuine short-cycling.
onFrac  = mean(duty);
onTime_s = sum(duty) * TS_CTRL;
if starts > 0
    mean_run_min = (onTime_s / starts) / 60;
else
    mean_run_min = NaN;
end

% Intervals spent pulsing below the modulation floor -- the diagnostic for
% "the tank is too small / the valves are not letting it charge".
frac_below_floor = mean(duty > DUTY_OFF & duty < 1 - DUTY_OFF);

% --- energy + cost ---
% The command is piecewise constant over the 15-min control grid, so a
% rectangle sum is exact here and a trapezoid would smear the last
% interval. W*s -> kWh via /3.6e6.
kWh        = sum(Elec)        * TS_CTRL / 3.6e6;
kWh_th     = sum(Heat)        * TS_CTRL / 3.6e6;
eur        = sum(Elec .* pk)  * TS_CTRL / 3.6e6;
avg_paid   = eur / max(kWh, eps);
mkt_mean   = mean(pk, 'omitnan');

% --- tank statistics (only if Ttank was logged) ---
Ttank = fetchOnTimeBase(out, tankLineName, tu);
if ~isempty(Ttank)
    tank_min   = min(Ttank);
    tank_max   = max(Ttank);
    tank_mean  = mean(Ttank);
    tank_swing = tank_max - tank_min;
    % Standing loss uses the same UA_tank and plant-room temp as the model.
    UA_TANK_W_K = 1.9;
    T_TECH_C    = 15;
    tank_loss_kWh = trapz(tu, UA_TANK_W_K * (Ttank - T_TECH_C)) / 3.6e6;

    % Energy left IN the tank at the end of the run, relative to the start.
    % Without this the tank version looks worse than the baseline purely
    % because it finished with a charged store: that heat was paid for but
    % not yet delivered, so a straight kWh comparison is unfair.
    C_TANK_J_K   = 2.093e6;
    tank_delta_kWh = C_TANK_J_K * (Ttank(end) - Ttank(1)) / 3.6e6;
else
    tank_min = NaN; tank_max = NaN; tank_mean = NaN;
    tank_swing = NaN; tank_loss_kWh = NaN; tank_delta_kWh = NaN;
end

% --- comfort: time outside the room bounds ---
Troom = fetchOnTimeBase(out, roomLineName, tu);
if ~isempty(Troom)
    try
        rmin = evalin('base','T_room_min');
        rmax = evalin('base','T_room_max');
    catch
        rmin = 19; rmax = 24;
    end
    dt        = [diff(tu); 0];
    hrs_below = sum(dt(Troom < rmin)) / 3600;
    hrs_above = sum(dt(Troom > rmax)) / 3600;
    max_room  = max(Troom);
    min_room  = min(Troom);
else
    hrs_below = NaN; hrs_above = NaN; max_room = NaN; min_room = NaN;
end

% --- report ---
fprintf('\n===== RUN SUMMARY (%.1f days) =====\n', days);
fprintf('HP compressor starts (cycles) : %d\n', starts);
fprintf('   -> %.1f cycles/day   (%.2f cycles/hour)\n', starts/days, starts/days/24);
fprintf('Mean run length per cycle     : %.1f min\n', mean_run_min);
fprintf('Compressor ON fraction        : %.1f %%\n', 100*onFrac);
fprintf('Intervals below modulation floor: %.1f %%\n', 100*frac_below_floor);
fprintf('Heat delivered                : %.1f kWh   (%.1f kWh/day)\n', kWh_th, kWh_th/days);
fprintf('Electricity consumed          : %.1f kWh   (%.1f kWh/day)\n', kWh, kWh/days);
if kWh > 0
    fprintf('Seasonal performance factor   : %.2f\n', kWh_th/kWh);
end
fprintf('Electricity cost (Tibber real): %.2f EUR\n', eur);
fprintf('Average price paid            : %.4f EUR/kWh  (market mean %.4f)\n', avg_paid, mkt_mean);
if ~isnan(max_room)
    fprintf('--- Comfort ---\n');
    fprintf('Room min / max                : %.1f / %.1f C\n', min_room, max_room);
    fprintf('Hours below lower bound       : %.1f h\n', hrs_below);
    fprintf('Hours above upper bound       : %.1f h\n', hrs_above);
end
if ~isnan(tank_min)
    fprintf('--- Buffer tank ---\n');
    fprintf('Ttank min / mean / max        : %.1f / %.1f / %.1f C\n', ...
        tank_min, tank_mean, tank_max);
    fprintf('Ttank swing                   : %.1f K\n', tank_swing);
    fprintf('Tank standing loss            : %.1f kWh  (%.2f kWh/day)\n', ...
        tank_loss_kWh, tank_loss_kWh/days);
    fprintf('Stored heat change (end-start): %+.1f kWh thermal\n', tank_delta_kWh);
    if tank_max < 35
        fprintf('   NOTE: peak tank temp < 35 C -- the tank is acting as a\n');
        fprintf('   damper, not a store. Expect little load-shifting headroom.\n');
    end
end
fprintf('=====================================\n');
if avg_paid < mkt_mean
    fprintf('Load shifting: paying %.1f %% BELOW the market mean.\n', ...
        100*(1 - avg_paid/mkt_mean));
elseif avg_paid > mkt_mean
    fprintf('Load shifting: paying %.1f %% ABOVE the market mean -- the\n', ...
        100*(avg_paid/mkt_mean - 1));
    fprintf(' controller is running preferentially in expensive hours.\n');
else
    fprintf('Load shifting: none (avg paid == market mean).\n');
end

results = struct('days',days, 'cycles',starts, 'cycles_per_day',starts/days, ...
                 'mean_run_min',mean_run_min, 'on_fraction',onFrac, ...
                 'frac_below_floor',frac_below_floor, 'kWh_thermal',kWh_th, ...
                 'kWh',kWh, 'cost_eur',eur, 'avg_price_eur_kWh',avg_paid, ...
                 'market_mean_eur_kWh',mkt_mean, ...
                 'room_min_C',min_room, 'room_max_C',max_room, ...
                 'hours_below_bound',hrs_below, 'hours_above_bound',hrs_above, ...
                 'tank_min_C',tank_min, 'tank_mean_C',tank_mean, ...
                 'tank_max_C',tank_max, 'tank_swing_K',tank_swing, ...
                 'tank_loss_kWh',tank_loss_kWh, 'tank_delta_kWh',tank_delta_kWh);

% --- plots: x axis in days (or hours for short runs), y in degrees C ---
figsBefore = findobj('Type','figure');
plot_run(tu, Tout, u, pk, out, roomLineName, tankLineName, days);

% --- persist everything to the results folder ---
results.runDir   = runDir;
results.runStamp = runStamp;
saveRunArtifacts(runDir, results, figsBefore);

fprintf('\nSaved to: %s\n', runDir);
diary off

end


function logBaseVar(name)
%LOGBASEVAR Print a base-workspace variable if it exists, for the run log.
try
    if evalin('base', sprintf('exist(''%s'',''var'')', name)) ~= 1
        return
    end
    v = evalin('base', name);
    if isdatetime(v)
        fprintf('  %-16s : %s\n', name, datestr(v));
    elseif isnumeric(v) && isscalar(v)
        fprintf('  %-16s : %g\n', name, v);
    elseif ischar(v) || isstring(v)
        fprintf('  %-16s : %s\n', name, string(v));
    end
catch
end
end


function saveRunArtifacts(runDir, results, figsBefore)
%SAVERUNARTIFACTS Write figures and the results struct into RUNDIR.
% Figures created during this call are saved both as .png (for quick
% viewing / pasting into the thesis) and .fig (so they stay zoomable and
% the underlying data can be recovered).

% Save the metrics struct and a flat text copy.
try
    save(fullfile(runDir, 'results.mat'), '-struct', 'results');
catch ME
    warning('analyze_run:saveResults', 'Could not save results.mat (%s).', ME.message);
end

try
    fid = fopen(fullfile(runDir, 'results.txt'), 'w');
    if fid > 0
        f = fieldnames(results);
        for k = 1:numel(f)
            v = results.(f{k});
            if isnumeric(v) && isscalar(v)
                fprintf(fid, '%-22s %g\n', f{k}, v);
            elseif ischar(v)
                fprintf(fid, '%-22s %s\n', f{k}, v);
            end
        end
        fclose(fid);
    end
catch ME
    warning('analyze_run:saveResultsTxt', 'Could not write results.txt (%s).', ME.message);
end

% Save every figure created since figsBefore was captured.
figsAfter = findobj('Type','figure');
newFigs   = setdiff(figsAfter, figsBefore);
if isempty(newFigs)
    newFigs = figsAfter;   % nothing new detected -- save whatever is open
end

% setdiff on graphics handles can leave deleted or non-figure entries in
% the result, which savefig rejects with "H must be an array of handles to
% valid figures". Filter to live figure handles only.
newFigs = newFigs(isgraphics(newFigs, 'figure'));

for k = 1:numel(newFigs)
    fh = newFigs(k);
    nm = get(fh, 'Name');
    if isempty(nm)
        nm = sprintf('figure%d', k);
    end
    nm = regexprep(nm, '[^\w-]', '_');       % filesystem-safe
    base = fullfile(runDir, sprintf('%02d_%s', k, nm));
    try
        exportgraphics(fh, [base '.png'], 'Resolution', 150);
    catch
        try
            saveas(fh, [base '.png']);        % pre-R2020a fallback
        catch ME
            warning('analyze_run:savePng', ...
                'Could not save figure %d as PNG (%s).', k, ME.message);
        end
    end
    try
        savefig(fh, [base '.fig']);
    catch ME
        warning('analyze_run:saveFig', ...
            'Could not save figure %d as .fig (%s).', k, ME.message);
    end
end
end


function ok = tryEnableLogging(L, wantName)
%TRYENABLELOGGING Turn on DataLogging for a line handle, tolerating lines
% that do not support it, and force the logged signal name to WANTNAME.
%
% Four cases have to be handled:
%  1. Simscape physical connection lines cannot be logged at all.
%  2. Branch segments cannot carry logging -- only the PARENT line can. A
%     named signal that fans out to several blocks is stored as a parent
%     plus one segment per branch, and find_system returns all of them.
%     Walk up via 'LineParent' first.
%  3. In newer Simulink releases 'DataLogging' is NOT a line property at
%     all -- it lives on the SOURCE OUTPUT PORT that the line leaves from.
%     Older releases accept it on the line. Try the line first, then fall
%     back to the port, so this works on both.
%  4. Even when logging is enabled, the name that ends up in logsout is
%     inherited and may not match the line name (it can fall back to the
%     source block name, or be blank). Set DataLoggingNameMode='Custom'
%     with an explicit DataLoggingName so logsout.get(wantName) is
%     guaranteed to resolve.
%
% Returns true only if logging was actually enabled.
ok = false;

% --- Walk up to the root of the branch tree ---
try
    parent = get_param(L, 'LineParent');
    while ~isempty(parent) && parent ~= -1 && ishandle(parent)
        L = parent;
        parent = get_param(L, 'LineParent');
    end
catch
    % No LineParent property -- not a Simulink signal line.
    return
end

% --- Path 1: older releases accept DataLogging on the line ---
try
    set_param(L, 'DataLogging', 'on');
    forceLogName(L, wantName);
    ok = true;
    return
catch
    % Fall through to the port-based path.
end

% --- Path 2: newer releases put DataLogging on the source output port ---
try
    ph = get_param(L, 'SrcPortHandle');
    if ~isempty(ph) && ph ~= -1 && ishandle(ph)
        set_param(ph, 'DataLogging', 'on');
        forceLogName(ph, wantName);
        ok = true;
    end
catch
    % Not loggable -- skip it silently.
end
end


function forceLogName(h, wantName)
%FORCELOGNAME Pin the logged signal name so logsout.get() can find it.
try
    set_param(h, 'DataLoggingNameMode', 'Custom');
    set_param(h, 'DataLoggingName', wantName);
catch
    % Older releases may not expose these; inherited naming will apply.
end
end


function ts = fetchLogged(out, name)
%FETCHLOGGED Pull a logged signal's Values by name, returning [] if absent.
%
% Two traps this guards against:
%  1. Dataset.get() returns an empty DOUBLE when the name is missing, so a
%     bare out.logsout.get(name).Values errors with a confusing "dot
%     indexing on type double".
%  2. When several lines share a name (e.g. a 'Room' line at the top level
%     AND one inside a subsystem), get() returns a Dataset of matches
%     rather than a single Signal. Take the first match in that case.
ts = [];
try
    el = out.logsout.get(name);
catch
    return   % no logsout at all
end
if isempty(el)
    return
end

% Multiple signals share this name -> unwrap to the first.
if isa(el, 'Simulink.SimulationData.Dataset')
    if el.numElements < 1
        return
    end
    warning('analyze_run:duplicateLogName', ...
        ['%d logged signals are named ''%s''. Using the first. Rename the ' ...
         'others to avoid ambiguity.'], el.numElements, name);
    el = el{1};
end

if isprop(el, 'Values')
    ts = el.Values;
end
end


function s = listLogged(out)
%LISTLOGGED Comma-separated names of everything in logsout, for diagnostics.
s = '(none)';
try
    n = out.logsout.numElements;
    if n > 0
        names = cell(1, n);
        for k = 1:n
            names{k} = out.logsout{k}.Name;
        end
        s = strjoin(names, ', ');
    end
catch
    s = '(logsout unavailable)';
end
end


function ts = fetchToWorkspace(out, varName)
%FETCHTOWORKSPACE Read a To Workspace variable from the SimulationOutput,
% falling back to the base workspace.
%
% When 'Single simulation output' is off, To Workspace blocks write
% straight into the base workspace instead of into the returned object,
% so both locations have to be checked.
ts = [];

v = [];
got = false;
try
    v = out.(varName);
    got = true;
catch
    % Not in the SimulationOutput -- try the base workspace.
end

if ~got
    try
        if evalin('base', sprintf('exist(''%s'',''var'')', varName)) == 1
            v = evalin('base', varName);
            got = true;
        end
    catch
        return
    end
end

if ~got
    return
end

if isa(v, 'timeseries')
    ts = v;
elseif isstruct(v) && isfield(v, 'time') && isfield(v, 'signals')
    % Structure With Time format.
    ts = timeseries(squeeze(v.signals.values), v.time);
end
end


function v = fetchOnTimeBase(out, name, tu)
%FETCHONTIMEBASE Fetch a signal by name and resample it onto time base TU.
% Tries the To Workspace variable '<name>_log' first, then signal logging.
% Returns [] if the signal is absent. Variable-step / zero-crossing
% solvers can emit duplicate time stamps, which interp1 rejects, so
% duplicates are collapsed first (keeping the last sample per instant).
v = [];
if isempty(name)
    return
end

rv = fetchToWorkspace(out, [name '_log']);
if isempty(rv)
    % The To Workspace variable name need not match the signal line's
    % name -- the line may be called 'Room' while the block writes
    % 'Troom_log'. Getting this wrong silently drops the trace, so try
    % the common spellings for whichever signal was asked for.
    if any(strcmpi(name, {'Room','Troom','T_room','room','Troom_C'}))
        alts = {'Troom_log','Room_log','T_room_log'};
    else
        alts = {'Ttank_log','Tank_log','T_tank_log'};
    end
    for k = 1:numel(alts)
        rv = fetchToWorkspace(out, alts{k});
        if ~isempty(rv), break; end
    end
end
if isempty(rv)
    rv = fetchLogged(out, name);
end
if isempty(rv), return; end

try
    rt = rv.Time(:);
    rd = double(rv.Data(:));
    [rt, iu] = unique(rt, 'last');
    rd = rd(iu);
    v  = interp1(rt, rd, tu, 'linear', 'extrap');
catch ME
    warning('analyze_run:resample', ...
        'Could not resample signal ''%s'' (%s).', name, ME.message);
end
end


function plot_run(tu, Tout, u, pk, out, roomLineName, tankLineName, days)
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

Troom = fetchOnTimeBase(out, roomLineName, tu);
Ttank = fetchOnTimeBase(out, tankLineName, tu);
if ~isempty(roomLineName) && isempty(Troom)
    warning('plot_run:roomFetch', ...
        'Room line ''%s'' was marked for logging but no data came back.', ...
        roomLineName);
end

figure('Name','Adaptive MPC run','Color','w');

% --- Panel 1: temperatures ---
ax1 = subplot(3,1,1);
plot(tPlot, Tout, 'LineWidth', 1.0, 'DisplayName','Environment'); hold on
if ~isempty(Troom)
    plot(tPlot, Troom, 'LineWidth', 1.0, 'DisplayName','Room');
end
if ~isempty(Ttank)
    plot(tPlot, Ttank, 'LineWidth', 1.0, 'DisplayName','Buffer tank');
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

