create_clock -name ca -period 10 [get_ports ca]
create_clock -name cb -period 7 [get_ports cb]
set_clock_groups -asynchronous -group {ca} -group {cb}
set_input_delay -clock cb 1.0 [get_ports en_d]
set_input_delay -clock ca 1.0 [get_ports d]
