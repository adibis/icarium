create_clock -name clk_a -period 10.0 [get_ports clk_a]
create_clock -name clk_b -period 7.5 [get_ports clk_b]
create_clock -name scan_clk -period 20.0 [get_ports scan_clk]
set_clock_groups -asynchronous -group {clk_a} -group {clk_b scan_clk}
set_input_delay -clock clk_a 1.0 [get_ports d_gated]
set_input_delay -clock clk_a 1.0 [get_ports d_rmux]
set_input_delay -clock clk_a 1.0 [get_ports d_clean]
set_input_delay -clock clk_a 1.0 [get_ports scan_en]
