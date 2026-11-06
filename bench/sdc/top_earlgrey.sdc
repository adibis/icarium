# Bench constraints for the EarlGrey top (tier 3). Chip clocks root
# at the four AST oscillator nets: analog, undriven in the
# netlist, declared here by netname. Frequencies come from the
# clkmgr ipconfig (main 100M, usb 48M, io 96M, aon 200k); async
# groups carry the crossing semantics, not the periods.
create_clock -name sys_osc -period 10 [get_nets earlgrey_pd_main.u_ast_part_primary.clk_osc_sys]
create_clock -name usb_osc -period 20.833 [get_nets earlgrey_pd_main.u_ast_part_primary.clk_osc_usb]
create_clock -name io_osc -period 10.417 [get_nets earlgrey_pd_main.u_ast_part_primary.clk_osc_io]
create_clock -name aon_osc -period 5000 [get_nets earlgrey_pd_aon.u_ast_part_secondary.clk_osc_aon]
create_clock -name ext -period 10 [get_ports clk_ast_ext_i]
create_clock -name osc_byp -period 10 [get_ports clks_osc_byp_i]
set_clock_groups -asynchronous -group {sys_osc} -group {usb_osc} -group {io_osc} -group {aon_osc} -group {ext} -group {osc_byp}
set_input_delay -clock ext [get_ports mio_in_i]
set_input_delay -clock ext [get_ports dio_in_i]
set_input_delay -clock ext [get_ports usbdev_usb_rx_d_i]
set_input_delay -clock ext [get_ports manual_in_por_n_i]
set_input_delay -clock ext [get_ports dft_hold_tap_sel_i]
set_input_delay -clock ext [get_ports cg_en_ast_ext_i]
set_input_delay -clock ext [get_ports ast_obs_i]
set_input_delay -clock ext [get_ports ast_vx_supp_i]
set_input_delay -clock ext [get_ports ast_adc_a0_a_i]
set_input_delay -clock ext [get_ports ast_adc_a1_a_i]
set_input_delay -clock ext [get_ports padmux2ast_i]
