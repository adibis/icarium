create_clock -name clk0 -period 10 [get_ports clk0]
create_clock -name clk1 -period 7 [get_ports clk1]
create_clock -name cs -period 13 [get_ports cs]
set_clock_groups -asynchronous -group {clk0} -group {clk1} -group {cs}
set_input_delay -clock clk0 1.0 [get_ports rst0]
set_input_delay -clock clk1 1.0 [get_ports rst1]
set_input_delay -clock cs 1.0 [get_ports sel_d]
