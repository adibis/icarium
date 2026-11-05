create_clock -name dst_clk -period 10.0 [get_ports dst_clk]
set_input_delay -clock dst_clk 1.0 [get_ports d_in]
