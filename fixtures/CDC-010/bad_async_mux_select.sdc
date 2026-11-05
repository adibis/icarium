create_clock -name ca -period 10 [get_ports ca]
create_clock -name cb -period 7 [get_ports cb]
create_clock -name cc -period 11 [get_ports cc]
set_clock_groups -asynchronous -group {ca} -group {cb} -group {cc}
set_input_delay -clock cc 1.0 [get_ports en_d]
set_input_delay -clock ca 1.0 [get_ports d]
