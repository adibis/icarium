create_clock -name wr_clk -period 10 [get_ports wr_clk]
create_clock -name rd_clk -period 7 [get_ports rd_clk]
set_clock_groups -asynchronous -group {wr_clk} -group {rd_clk}
