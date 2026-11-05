create_clock -name fc -period 4 [get_ports fc]
create_clock -name sc -period 10 [get_ports sc]
set_clock_groups -asynchronous -group {fc} -group {sc}
set_input_delay -clock fc 1.0 [get_ports stim]
