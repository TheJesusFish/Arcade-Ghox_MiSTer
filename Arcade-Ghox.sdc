derive_pll_clocks
derive_clock_uncertainty

create_generated_clock -name SDRAM_CLK -source \
    [get_pins {emu|pll|raizingpll_inst|altera_pll_i|general[5].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -divide_by 1 \
    [get_ports SDRAM_CLK]

# joy_db15 captures its serial input on JCLOCKS[4]. JTFRAME_SDRAM96 selects
# counter bit 4, so this fabric clock is exactly clk_sys / 32.
create_generated_clock -name DB15_JOY_CLK -source \
    [get_pins {emu|u_joymux|u_db15|JCLOCKS[0]|clk}] \
    -divide_by 32 \
    [get_pins {emu|u_joymux|u_db15|JCLOCKS[4]|q}]

set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to [get_clocks {emu|pll|raizingpll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] -setup -end 2
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to [get_clocks {emu|pll|raizingpll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] -hold -end 2

# The restored shell uses the Raizing PLL instance. Keep SDRAM/game clocks
# related and cut unrelated framework, audio, video, and HPS clock domains.
set_clock_groups -exclusive \
    -group [get_clocks {emu|pll|raizingpll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk emu|pll|raizingpll_inst|altera_pll_i|general[5].gpll~PLL_OUTPUT_COUNTER|divclk SDRAM_CLK}] \
    -group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}] \
    -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -group [get_clocks {spi_sck}] \
    -group [get_clocks {hdmi_sck}] \
    -group [get_clocks {sysmem|fpga_interfaces|clocks_resets|h2f_user0_clk}] \
    -group [get_clocks {FPGA_CLK1_50}] \
    -group [get_clocks {FPGA_CLK2_50}] \
    -group [get_clocks {FPGA_CLK3_50}]

# SDRAM timing constraints for the inlined JTFrame/MiSTer hierarchy.
set_multicycle_path -setup -end -from [get_keepers {SDRAM_DQ[*]}] -to [get_keepers {emu:emu|jtframe_board:u_board|jtframe_board_sdram:u_sdram|jtframe_sdram64:u_sdram|dout[*]}] 2
set_multicycle_path -hold  -end -from [get_keepers {SDRAM_DQ[*]}] -to [get_keepers {emu:emu|jtframe_board:u_board|jtframe_board_sdram:u_sdram|jtframe_sdram64:u_sdram|dout[*]}] 2
set_multicycle_path -setup -end -from [get_keepers {emu:emu|jtframe_board:u_board|jtframe_board_sdram:u_sdram|jtframe_sdram64:u_sdram|dq_pad[*]}] -to [get_keepers {SDRAM_DQ[*]}] 2
set_multicycle_path -hold  -end -from [get_keepers {emu:emu|jtframe_board:u_board|jtframe_board_sdram:u_sdram|jtframe_sdram64:u_sdram|dq_pad[*]}] -to [get_keepers {SDRAM_DQ[*]}] 2
set_multicycle_path -setup -end -from [get_keepers {emu:emu|jtframe_board:u_board|jtframe_board_sdram:u_sdram|jtframe_sdram64:u_sdram|sdram_a[12]}] -to [get_keepers {SDRAM_DQMH}] 2
set_multicycle_path -hold  -end -from [get_keepers {emu:emu|jtframe_board:u_board|jtframe_board_sdram:u_sdram|jtframe_sdram64:u_sdram|sdram_a[12]}] -to [get_keepers {SDRAM_DQMH}] 2
set_multicycle_path -setup -end -from [get_keepers {emu:emu|jtframe_board:u_board|jtframe_board_sdram:u_sdram|jtframe_sdram64:u_sdram|sdram_a[11]}] -to [get_keepers {SDRAM_DQML}] 2
set_multicycle_path -hold  -end -from [get_keepers {emu:emu|jtframe_board:u_board|jtframe_board_sdram:u_sdram|jtframe_sdram64:u_sdram|sdram_a[11]}] -to [get_keepers {SDRAM_DQML}] 2

# The HD647180/T80 architectural state advances on sound_cpu_cen.  Its
# 20/189 accumulator at 94.5 MHz produces a 10 MHz enable with a minimum
# separation of nine master-clock edges.  Scope this exception only between
# registers inside the CPU; wrapper state-load and external bus paths remain
# single-cycle checked.
set ghox_t80_keepers [get_keepers {*|ghox_hd647180:u_sound_cpu|T80:cpu|*}]
set_multicycle_path -setup -end -from $ghox_t80_keepers -to $ghox_t80_keepers 9
set_multicycle_path -hold  -end -from $ghox_t80_keepers -to $ghox_t80_keepers 8

# The TP-021 raster advances once every 14 master clocks (94.5 / 14 =
# 6.75 MHz). Constrain only the board's pixel-enable registered outputs.
set ghox_video_keepers [get_keepers {
    *|ghox_board:u_board|red_o[*]
    *|ghox_board:u_board|green_o[*]
    *|ghox_board:u_board|blue_o[*]
    *|ghox_board:u_board|lhbl_o
    *|ghox_board:u_board|lvbl_o
    *|ghox_board:u_board|hs_o
    *|ghox_board:u_board|vs_o
}]
set_multicycle_path -setup -end -from [get_clocks {emu|pll|raizingpll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -to $ghox_video_keepers 14
set_multicycle_path -hold -end -from [get_clocks {emu|pll|raizingpll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -to $ghox_video_keepers 13

# JTFrame framework exceptions.
set_false_path -to [get_keepers {audio_out:audio_out|cl1[*]}]
set_false_path -to [get_keepers {audio_out:audio_out|cr1[*]}]
set_false_path -from [get_keepers {emu:emu|jtframe_board:u_board|jtframe_reset:u_reset|rst_rom[0]}] -to [get_keepers {emu:emu|jtframe_board:u_board|jtframe_reset:u_reset|rst_rom_sync}]
set_false_path -to emu:emu|jtframe_board:u_board|jtframe_reset:u_reset|rst_req_sync[0]
set_false_path -from FB_EN
set_false_path -to deb_osd[0]
set_false_path -from emu:emu|jtframe_board:u_board|jtframe_led:u_led|led
set_false_path -to [get_keepers {*altera_std_synchronizer:*|din_s1}]
