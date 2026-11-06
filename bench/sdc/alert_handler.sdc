# Bench constraints for OpenTitan alert_handler (tier 2). Two unrelated
# clocks: the bus clock and the EDN clock each type their own inputs,
# so untyped-port noise stays out of the head-to-head numbers.
create_clock -name clk -period 10 [get_ports clk_i]
create_clock -name clk_edn -period 10 [get_ports clk_edn_i]
set_clock_groups -asynchronous -group {clk} -group {clk_edn}
set_input_delay -clock clk [get_ports tl_i]
set_input_delay -clock clk [get_ports alert_tx_i]
set_input_delay -clock clk [get_ports esc_rx_i]
set_input_delay -clock clk [get_ports lpg_cg_en_i]
set_input_delay -clock clk [get_ports lpg_rst_en_i]
set_input_delay -clock clk [get_ports rst_ni]
set_input_delay -clock clk [get_ports rst_shadowed_ni]
set_input_delay -clock clk_edn [get_ports edn_i]
set_input_delay -clock clk_edn [get_ports rst_edn_ni]
