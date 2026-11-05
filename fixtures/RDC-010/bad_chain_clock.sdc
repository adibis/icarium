create_clock -name clk_a -period 10.0 [get_ports clk_a]
create_clock -name clk_b -period 7.0 [get_ports clk_b]
set_clock_groups -asynchronous -group {clk_a} -group {clk_b}
set_input_delay -clock clk_b 1.0 [get_ports d]
