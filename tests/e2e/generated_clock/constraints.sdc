create_clock -name clk -period 10 [get_ports clk]
create_generated_clock -name div_clk -source clk -divide_by 2 [get_pins div/Q]
