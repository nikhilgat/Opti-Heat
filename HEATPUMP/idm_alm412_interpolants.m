function hp = idm_alm412_interpolants()

d = idm_alm412_datasheet();

[T_air_sorted, sort_idx] = sort(d.T_air, 'ascend');

P_th_max_sorted = d.P_th_max_kW(:, sort_idx);
P_th_min_sorted = d.P_th_min_kW(:, sort_idx);
P_el_max_sorted = d.P_el_max_kW(:, sort_idx);
P_el_min_sorted = d.P_el_min_kW(:, sort_idx);

hp.data = d;

hp.Pth_max = griddedInterpolant({d.T_supply, T_air_sorted}, P_th_max_sorted, 'linear', 'nearest');
hp.Pth_min = griddedInterpolant({d.T_supply, T_air_sorted}, P_th_min_sorted, 'linear', 'nearest');
hp.Pel_max = griddedInterpolant({d.T_supply, T_air_sorted}, P_el_max_sorted, 'linear', 'nearest');
hp.Pel_min = griddedInterpolant({d.T_supply, T_air_sorted}, P_el_min_sorted, 'linear', 'nearest');

hp.Tair_min = min(d.T_air);
hp.Tair_max = max(d.T_air);
hp.Tsupply_min = min(d.T_supply);
hp.Tsupply_max = max(d.T_supply);

hp.getPthMax = @(Tair,Tsupply) hp.Pth_max(Tsupply,Tair);
hp.getPthMin = @(Tair,Tsupply) hp.Pth_min(Tsupply,Tair);
hp.getPelMax = @(Tair,Tsupply) hp.Pel_max(Tsupply,Tair);
hp.getPelMin = @(Tair,Tsupply) hp.Pel_min(Tsupply,Tair);

hp.getPerformance = @(Tair,Tsupply,u) interpolatePerformance(hp,Tair,Tsupply,u);

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
