create_clock -name src_clk -period 2.0  [get_ports src_clk]
create_clock -name dst_clk -period 20.0 [get_ports dst_clk]
set_clock_groups -asynchronous -group {src_clk} -group {dst_clk}
set_input_delay -clock src_clk 0.5 [get_ports event_in]
