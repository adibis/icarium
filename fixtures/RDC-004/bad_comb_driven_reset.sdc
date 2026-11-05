create_clock -name clk -period 10.0 [get_ports clk]
set_input_delay -clock clk 1.0 [get_ports kill_a]
set_input_delay -clock clk 1.0 [get_ports kill_b]
set_input_delay -clock clk 1.0 [get_ports d_in]
