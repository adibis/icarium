# Bench constraints for OpenTitan gpio (tier 2). Fully typed: one clock,
# every data input delayed into it, so untyped-port noise stays out of
# the head-to-head numbers.
create_clock -name clk -period 10 [get_ports clk_i]
set_input_delay -clock clk [get_ports tl_i]
set_input_delay -clock clk [get_ports cio_gpio_i]
set_input_delay -clock clk [get_ports alert_rx_i]
set_input_delay -clock clk [get_ports racl_policies_i]
set_input_delay -clock clk [get_ports rst_ni]
set_input_delay -clock clk [get_ports strap_en_i]
