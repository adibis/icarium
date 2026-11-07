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
# Divided clocks root at their clk_int nets: counter dividers
# are not toggle flops, so the tracer cannot count their Q.
# Async to everything including masters, mirroring OpenTitan's
# own CDC groups (chip_earlgrey_asic.sdc group1).
create_generated_clock -name io_div2 -source io_osc -divide_by 2 [get_nets earlgrey_pd_aon.u_clkmgr.u_no_scan_io_div2_div.clk_int]
create_generated_clock -name io_div4 -source io_osc -divide_by 4 [get_nets earlgrey_pd_aon.u_clkmgr.u_no_scan_io_div4_div.clk_int]
create_generated_clock -name usb_div240 -source usb_osc -divide_by 240 [get_nets earlgrey_pd_main.u_ast_part_primary.u_ast_clks_byp_primary.u_no_scan_clk_usb_div240_div.clk_int]
# SPI serial clock at the mux input nets: the dio pad carries sck
# beside data, so the whole pad cannot root. Both mux inputs
# trace to the sck pad bit. Period from OpenTitan's SPI_DEV_TCK.
create_clock -name spi_sck -period 20 [get_nets earlgrey_pd_main.u_spi_device.u_clk_spi_in_mux.clk0_i] [get_nets earlgrey_pd_main.u_spi_device.u_clk_spi_out_mux.clk0_i]
# I3C target serial clocks at their mux inputs; same pad-sharing
# argument as SPI. 80ns is I3C SDR max rate, nominal only.
create_clock -name i3c0_scl -period 80 [get_nets earlgrey_pd_main.u_i3c0_part_primary.u_core.u_targ_inbufs.u_scl_inv.u_mux.clk0_i] [get_nets earlgrey_pd_main.u_i3c0_part_primary.u_core.u_targ_inbufs.u_scl_buf.u_mux.clk0_i]
create_clock -name i3c1_scl -period 80 [get_nets earlgrey_pd_main.u_i3c1_part_primary.u_core.u_targ_inbufs.u_scl_inv.u_mux.clk0_i] [get_nets earlgrey_pd_main.u_i3c1_part_primary.u_core.u_targ_inbufs.u_scl_buf.u_mux.clk0_i]
# JTAG TCK at the TAP mux inputs: both trace to mio pad bit 8
# through the tap-enable flops. Period is OpenTitan's TCK target.
create_clock -name rv_tck -period 33.3 [get_nets earlgrey_pd_main.u_rv_dm.gen_jtag_gating.u_prim_clock_mux2.clk0_i]
create_clock -name lc_tck -period 33.3 [get_nets earlgrey_pd_main.u_lc_ctrl.gen_tap_tlul.u_prim_clock_mux2.clk0_i]
set_clock_groups -asynchronous -group {sys_osc} -group {usb_osc} -group {io_osc} -group {aon_osc} -group {ext} -group {osc_byp} -group {io_div2} -group {io_div4} -group {usb_div240} -group {spi_sck} -group {i3c0_scl} -group {i3c1_scl} -group {rv_tck} -group {lc_tck}
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
