create_clock -name clkA -period 10.0 [get_ports clkA]
create_clock -name clkB -period 7.0  [get_ports clkB]
create_generated_clock -name gdiv_clk -source clkA -divide_by 2 [get_pins gdiv_reg/Q]
set_clock_groups -asynchronous -group {clkA} -group {clkB} -group {gdiv_clk}
set_input_delay -clock clkA 1.0 [get_ports din]
