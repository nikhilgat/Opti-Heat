function hp = idm_alm412_interpolants()
%IDM_ALM412_INTERPOLANTS Gridded lookups for the IDM AERO ALM 4-12.
%
% Envelope handling (replaces the old 30 kW resistive fallback):
%   * The raw datasheet grids contain NaN holes at high flow temperature /
%     low outdoor temperature (e.g. 70 C supply at -20 C air) -- operating
%     points the machine simply cannot reach.
%   * griddedInterpolant propagates those NaNs into any interpolation that
%     touches them, which previously triggered a 30162 W COP-1 resistive
%     heater: roughly 3x the building design load, silently and with no
%     warning.
%   * Instead the grids are NaN-filled along the T_supply dimension by
%     holding the last valid (lower) flow temperature. This is a physical
%     clamp -- the machine delivers what it can at its highest achievable
%     flow temperature -- and it keeps the interpolants NaN-free.
%   * hp.maxValidSupply(T_air) and hp.inEnvelope(T_air, T_supply) expose
%     the true measured envelope so callers can warn when they are running
%     on filled (clamped) data rather than datasheet data.
%
% The heating curve caps supply at 55 C, so in normal operation the filled
% region is never entered. The clamp exists so that if it ever is, the
% result degrades gracefully instead of jumping to a fictitious heater.

d = idm_alm412_datasheet();

[T_air_sorted, sort_idx] = sort(d.T_air, 'ascend');

P_th_max_sorted = d.P_th_max_kW(:, sort_idx);
P_th_min_sorted = d.P_th_min_kW(:, sort_idx);
P_el_max_sorted = d.P_el_max_kW(:, sort_idx);
P_el_min_sorted = d.P_el_min_kW(:, sort_idx);

% True envelope, taken from the max-capacity grid BEFORE filling: for each
% outdoor temperature, the highest flow temperature with measured data.
validMask    = ~isnan(P_th_max_sorted);
lastValidRow = zeros(1, numel(T_air_sorted));
for k = 1:numel(T_air_sorted)
    lastValidRow(k) = find(validMask(:, k), 1, 'last');
end
maxValidSupply_vec = d.T_supply(lastValidRow);

% Fill NaN holes by holding the last valid lower flow temperature.
P_th_max_filled = fillDownRows(P_th_max_sorted);
P_th_min_filled = fillDownRows(P_th_min_sorted);
P_el_max_filled = fillDownRows(P_el_max_sorted);
P_el_min_filled = fillDownRows(P_el_min_sorted);

hp.data = d;

hp.Pth_max = griddedInterpolant({d.T_supply, T_air_sorted}, P_th_max_filled, 'linear', 'nearest');
hp.Pth_min = griddedInterpolant({d.T_supply, T_air_sorted}, P_th_min_filled, 'linear', 'nearest');
hp.Pel_max = griddedInterpolant({d.T_supply, T_air_sorted}, P_el_max_filled, 'linear', 'nearest');
hp.Pel_min = griddedInterpolant({d.T_supply, T_air_sorted}, P_el_min_filled, 'linear', 'nearest');

hp.Tair_min    = min(d.T_air);
hp.Tair_max    = max(d.T_air);
hp.Tsupply_min = min(d.T_supply);
hp.Tsupply_max = max(d.T_supply);

% Highest measured flow temperature as a function of outdoor temperature.
hp.maxValidSupply = griddedInterpolant(T_air_sorted, maxValidSupply_vec, 'previous', 'nearest');

hp.inEnvelope = @(Tair, Tsupply) ...
    Tair    >= hp.Tair_min    && Tair    <= hp.Tair_max && ...
    Tsupply >= hp.Tsupply_min && Tsupply <= hp.maxValidSupply(Tair);

hp.getPthMax = @(Tair,Tsupply) hp.Pth_max(Tsupply,Tair);
hp.getPthMin = @(Tair,Tsupply) hp.Pth_min(Tsupply,Tair);
hp.getPelMax = @(Tair,Tsupply) hp.Pel_max(Tsupply,Tair);
hp.getPelMin = @(Tair,Tsupply) hp.Pel_min(Tsupply,Tair);

hp.getPerformance = @(Tair,Tsupply,u) interpolatePerformance(hp,Tair,Tsupply,u);

end

function M = fillDownRows(M)
%FILLDOWNROWS Replace NaN with the last valid value further up the column
% (i.e. the next-lower flow temperature). Columns are outdoor temperature,
% rows are flow temperature in ascending order.
for k = 1:size(M, 2)
    for r = 2:size(M, 1)
        if isnan(M(r, k))
            M(r, k) = M(r-1, k);
        end
    end
end
end

function perf = interpolatePerformance(hp,Tair,Tsupply,u)
u = max(0,min(1,u));
U_OFF = 0.05;   % below this the compressor is OFF (no heat, no power)

if u < U_OFF
    Pth = 0;
    Pel = 0;
else
    Pth_max = hp.getPthMax(Tair,Tsupply);
    Pth_min = hp.getPthMin(Tair,Tsupply);
    Pel_max = hp.getPelMax(Tair,Tsupply);
    Pel_min = hp.getPelMin(Tair,Tsupply);
    Pth = Pth_min + u*(Pth_max-Pth_min);   % min-modulation floor when ON
    Pel = Pel_min + u*(Pel_max-Pel_min);
end

if Pel > 0
    COP = Pth/Pel;
else
    COP = 0;
end

perf.Pth = Pth;
perf.Pel = Pel;
perf.COP = COP;
end
