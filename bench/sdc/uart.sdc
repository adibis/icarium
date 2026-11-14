# Bench constraints for OpenTitan uart (tier 2). Fully typed: one clock,
# every data input delayed into it, so untyped-port noise stays out of
# the head-to-head numbers.
create_clock -name clk -period 10 [get_ports clk_i]
# The TX pin leaves for pinmux, which OpenTitan calls clock
# invariant: a virtual clock asynchronous to clk models that.
create_clock -name virt_ext -period 10
set_clock_groups -asynchronous -group {clk} -group {virt_ext}
set_input_delay -clock clk [get_ports tl_i]
set_input_delay -clock clk [get_ports cio_rx_i]
set_input_delay -clock clk [get_ports alert_rx_i]
set_input_delay -clock clk [get_ports racl_policies_i]
set_input_delay -clock clk [get_ports rst_ni]
set_output_delay -clock virt_ext [get_ports cio_tx_o]
