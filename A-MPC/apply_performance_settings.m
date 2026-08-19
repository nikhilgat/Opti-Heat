% apply_performance_settings.m
%
% One-time speedup for HouseHeatingSystem sim runs on this machine
% (Intel Ultra 7 255H, 64GB RAM). Run this once from the MATLAB
% Command Window (or F5 this file) with the model closed or open --
% either is fine, it will load it if needed.
%
% What this does and why:
%   1. SimulationMode -> 'accelerator'
%      The model currently runs in 'normal' (interpreted) mode, which
%      re-interprets the block diagram every step. Accelerator mode
%      compiles the model to a MEX file once and then runs compiled
%      code -- this is the single biggest lever for a Simscape + MPC
%      model like this one. GPU is not applicable here (no GPU solver
%      path for small serial ODE/Simscape/QP work), and the state/
%      matrices are too small for CPU multithreading of the linear
%      algebra to matter -- compiled vs. interpreted execution is
%      what's actually slow.
%   2. SimscapeCompileArtifactsDiskCache -> 'on'
%      Persists the compiled Simscape artifacts to disk so repeated
%      runs (e.g. parameter sweeps across many calls to analyze_run)
%      don't pay the Simscape compile cost every single time.
%   3. Report whether Parallel Computing Toolbox is available, since
%      that's the correct way to use extra CPU cores here: running
%      multiple independent parsim() sweeps concurrently, not
%      speeding up a single run's math.

% 2026-08-19: this used to set 'accelerator' unconditionally. On a machine
% with no C compiler configured, Accelerator/Rapid-Accelerator mode fails
% at sim() time with "No supported compiler detected" -- and because this
% script SAVES the .slx, that failure persists into every future session
% until someone notices and manually sets SimulationMode back to 'normal'.
% That is exactly what happened here: several runs silently produced no
% results.txt for this reason before it was traced. Check for a compiler
% first and fall back to 'normal' rather than saving a mode that cannot
% run on this machine.
modelName = 'HouseHeatingSystem';

wasLoaded = bdIsLoaded(modelName);
if ~wasLoaded
    load_system(fullfile(fileparts(mfilename('fullpath')), '..', 'SIM-MODEL', [modelName '.slx']));
end

hasCompiler = ~isempty(mex.getCompilerConfigurations('C', 'Selected'));
if hasCompiler
    set_param(modelName, 'SimulationMode', 'accelerator');
else
    set_param(modelName, 'SimulationMode', 'normal');
    warning('apply_performance_settings:noCompiler', ...
        ['No C compiler is configured (mex -setup C) -- Accelerator mode ' ...
         'would fail at sim() time with "No supported compiler detected". ' ...
         'Leaving SimulationMode = ''normal''. Install a supported compiler ' ...
         '(e.g. MATLAB Support for MinGW-w64) and re-run this script to ' ...
         'enable Accelerator mode.']);
end
set_param(modelName, 'SimscapeCompileArtifactsDiskCache', 'on');

fprintf('SimulationMode                  : %s\n', get_param(modelName, 'SimulationMode'));
fprintf('SimscapeCompileArtifactsDiskCache: %s\n', get_param(modelName, 'SimscapeCompileArtifactsDiskCache'));

hasPCT = license('test', 'Distrib_Computing_Toolbox') && ~isempty(ver('parallel'));
fprintf('Parallel Computing Toolbox available: %d\n', hasPCT);

save_system(modelName);
fprintf('Saved %s.slx with new settings.\n', modelName);

if ~wasLoaded
    close_system(modelName);
end
