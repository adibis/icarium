# Bench constraints for OpenTitan spi_device (tier 2). System and SPI
# serial clocks declared asynchronous; data inputs deliberately
# untyped so the conservative-unknown path is measured, not assumed.
create_clock -name sys -period 10 [get_ports clk_i]
create_clock -name spi -period 25 [get_ports cio_sck_i]
set_clock_groups -asynchronous -group {sys} -group {spi}
