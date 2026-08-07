%% House Heating System
% 
% This example shows how to model a simple house heating system.  The model
% contains a heater, thermostat, and a house structure with four parts:
% inside air, house walls, windows, and roof.
% 
% Copyright 2008-2025 The MathWorks, Inc.

%% 1. Set the Plot View & Load Weather
set(groot, 'defaultFigureColor', 'w');
set(groot, 'defaultAxesColor', 'w');
set(groot, 'defaultAxesXColor', 'k');
set(groot, 'defaultAxesYColor', 'k');
set(groot, 'defaultTextColor', 'k');

open_system('HouseHeatingSystem')
weatherData = readtable('weather_langenhagen_2025.csv');
time_sec = (0:(height(weatherData)-1))' * 900;
weather_ts = timeseries(weatherData.T_out_C, time_sec);
weather_ts.Name = 'Real_Weather_Data';

%% 2. Ensure Weather Data Blocks Use the Correct Variable
set_param('HouseHeatingSystem/Daily Temp Variation1', 'VariableName', 'weather_ts');
set_param('HouseHeatingSystem/Daily Temp Variation2', 'VariableName', 'weather_ts');

%% 3. Define House Physical Parameters (Extracted from Workspace)
% Units
% h_A_Wnd = 25W/(m2K) ; windowArea = 6m2; LWindow = 0.01m ; kWindow = 0.78W/(mK) ; h_Wnd_Atm = 32W/(m2K);

% Windows
h_A_Wnd = 25 ; windowArea = 6; LWindow = 0.01; kWindow = 0.78; h_Wnd_Atm = 32;
% Walls
h_A_W = 24; wallArea = 320; LWall = 0.2; kWall = 0.038; h_W_Atm = 34;
% Roof
h_A_R = 12; roofArea = 601.08; LRoof = 0.2; kRoof = 0.038; h_R_Atm = 38;
% Air & Heater
M_air = 1496; c_air = 1005.4; HeaterAirFlow = 1; THeater = 50; TinIC = 20; Ts = 900;

%% 4. Calculate Exact House Parameters for State-Space
% Calculate thermal resistance for each path (Convection In + Conduction + Convection Out)
R_wnd  = (1 / (h_A_Wnd * windowArea)) + (LWindow / (kWindow * windowArea)) + (1 / (h_Wnd_Atm * windowArea));
R_wall = (1 / (h_A_W * wallArea))     + (LWall / (kWall * wallArea))       + (1 / (h_W_Atm * wallArea));
R_roof = (1 / (h_A_R * roofArea))     + (LRoof / (kRoof * roofArea))       + (1 / (h_R_Atm * roofArea));

% Total Equivalent Resistance (Parallel paths)
Req = 1 / ((1/R_wnd) + (1/R_wall) + (1/R_roof));

% Thermal Capacitance of the room air
C_air = M_air * c_air; 

% Maximum Heater Output (Watts)
Qmax = HeaterAirFlow * c_air * (THeater - TinIC);

%% 5. Define the State-Space Plant (1-State Model)
A = -1 / (Req * C_air);
B = [Qmax / C_air,  1 / (Req * C_air)]; % [MV (Heater), MD (Weather)]
C_mat = 1;                              % Output is the state (Troom)
D_mat = [0, 0];

plant_c = ss(A, B, C_mat, D_mat);
plant_d = c2d(plant_c, Ts);
plant_d = setmpcsignals(plant_d, 'MV', 1, 'MD', 2);

%% 6. Design the MPC
p = 48;
m = 5;
mpcobj = mpc(plant_d, Ts, p, m);

% Define Nominal Conditions so the MPC doesn't assume absolute zero
mpcobj.Model.Nominal.U = [0, weather_ts.Data(1)]; 
mpcobj.Model.Nominal.Y = TinIC;                      
mpcobj.Model.Nominal.X = TinIC; % The state itself is the room temperature

% Constraints and Tuning
mpcobj.MV(1).Min = 0;
mpcobj.MV(1).Max = 1;
mpcobj.Weights.MVRate = 0.1; 
mpcobj.Weights.OV = 1.0;

%% 7. Configure and Run the Simulation
% Set the stop time to match 10 days of your weather data
set_param('HouseHeatingSystem', 'StopTime', num2str(time_sec(960)));

% Tell the Scope to pop open automatically
set_param('HouseHeatingSystem/Heating Results', 'open', 'on');

% RUN THE SIMULATION (Only called once now)
sim('HouseHeatingSystem');

%% Calculate and Print the Total Cost
% 1. Set the new electricity price (0.30 per kWh)
price_per_kWh = 0.30; 

% 2. Convert to Cost per Joule (Simulink works in Watts = Joules/sec)
cost_per_joule = price_per_kWh / 3.6e6; 
assignin('base', 'cost', cost_per_joule); % Update the base workspace variable

% 3. Force the Scope to log its data to the workspace
set_param('HouseHeatingSystem/Heating Results', 'DataLogging', 'on');
set_param('HouseHeatingSystem/Heating Results', 'DataLoggingVariableName', 'heating_log');
set_param('HouseHeatingSystem/Heating Results', 'DataLoggingSaveFormat', 'Dataset');

% 4. Run the simulation AND force a modern SimulationOutput object
out = sim('HouseHeatingSystem', 'ReturnWorkspaceOutputs', 'on');

% 5. Extract the final cost
scope_dataset = out.get('heating_log');

% getElement(1) contains the Temperatures from Port 1
% getElement(2) contains the Cost from Port 2
cost_signal = scope_dataset.getElement(2).Values.Data;

% The cost is a single column, so we just grab the very last row
total_cost = cost_signal(end);

% 6. Print the results to the terminal
fprintf('\n==================================================\n');
fprintf('Electricity Rate : %.2f / kWh\n', price_per_kWh);
fprintf('Total Cost (10d) : %.2f\n', total_cost);
fprintf('==================================================\n\n');