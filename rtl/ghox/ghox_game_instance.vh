// Ghox-local JTFrame game instantiation. The shared framework include cannot
// express the raw index-1 GHXM stream or the GHSS0001 state-bus ports, so the
// boundary is kept here without modifying protected JTFrame sources.

localparam STARTW = 4;

wire [16:0] sram_addr;
wire [15:0] sram_din, sram_dout;
wire [1:0] sram_dsn;
wire sram_wen, sram_ok;

wire [15:0] sav_din, sav_dout, sav_addr;
wire sav_change, sav_wait, sav_done, sav_ack;
wire [1:0] sav_wr;

`ifdef SIMULATION
assign sim_hb         = ~LHBL;
assign sim_vb         = ~LVBL;
assign sim_pxl_clk    = clk_sys;
assign sim_pxl_cen    = pxl_cen;
assign sim_dwnld_busy = dwnld_busy;
`endif

ghox_game #(.AW(SDRAMW)) u_game (
    .rst                         (game_rst),
    .cold_rst                    (rst),
    .clk                         (clk_rom),
    .pxl2_cen                    (pxl2_cen),
    .pxl_cen                     (pxl_cen),
    .red                         (red),
    .green                       (green),
    .blue                        (blue),
    .LHBL                        (LHBL),
    .LVBL                        (LVBL),
    .HS                          (hs),
    .VS                          (vs),
    .joystick1                   (game_joy1[5:0]),
    .joystick2                   (game_joy2[5:0]),
    .cab_1p                      (game_start[STARTW-1:0]),
    .coin                        (game_coin[STARTW-1:0]),
    .service                     (game_service),
    .tilt                        (game_tilt),
    .dip_test                    (dip_test),
    .dip_pause                   (dip_pause),
    .dip_flip                    (dip_flip),
    .dipsw                       (dipsw),
    .status                      (status),
    .spinner_1p                  (spinner_1),
    .spinner_2p                  (spinner_2),
    .ioctl_addr                  (ioctl_addr),
    .ioctl_dout                  (ioctl_dout),
    .ioctl_wr                    (ioctl_wr),
    .ioctl_rom                   (ioctl_rom),
    .ioctl_din                   (ioctl_din),
    .dwnld_busy                  (dwnld_busy),
    .hps_download                (hps_download),
    .hps_index                   (hps_index),
    .hps_wr                      (hps_wr),
    .hps_rd                      (hps_rd),
    .hps_addr                    (hps_addr),
    .hps_dout                    (hps_dout),
    .hs_config_download          (hps_download && hs_config_selected),
    .hs_nvram_download           (hps_download && hs_nvram_selected),
    .hs_nvram_upload             (hps_upload && hs_nvram_selected),
    .hs_nvram_q                  (hs_nvram_q),
    .hs_nvram_wait               (hs_nvram_wait),
    .hs_dirty                    (hs_dirty),
    .hs_ready                    (hs_ready),
    .hs_active                   (hs_active),
    .data_read                   (sdram_dout),
    .ba0_addr                    (ba0_addr),
    .ba1_addr                    (ba1_addr),
    .ba2_addr                    (ba2_addr),
    .ba3_addr                    (ba3_addr),
    .ba_rd                       (ba_rd),
    .ba_wr                       (ba_wr),
    .ba_dst                      (ba_dst),
    .ba_dok                      (ba_dok),
    .ba_rdy                      (ba_rdy),
    .ba_ack                      (ba_ack),
    .ba0_din                     (ba0_din),
    .ba0_dsn                     (ba0_dsn),
    .ba1_din                     (ba1_din),
    .ba1_dsn                     (ba1_dsn),
    .ba2_din                     (ba2_din),
    .ba2_dsn                     (ba2_dsn),
    .ba3_din                     (ba3_din),
    .ba3_dsn                     (ba3_dsn),
    .prog_ba                     (prog_ba),
    .prog_rdy                    (prog_rdy),
    .prog_ack                    (prog_ack),
    .prog_dok                    (prog_dok),
    .prog_dst                    (prog_dst),
    .prog_data                   (prog_data),
    .prog_addr                   (prog_addr),
    .prog_rd                     (prog_rd),
    .prog_we                     (prog_we),
    .prog_mask                   (prog_mask),
    .snd_left                    (snd_left),
    .snd_right                   (snd_right),
    .sample                      (sample),
    .snd_en                      (snd_en),
    .snd_vol                     (snd_vol),
    .snd_vu                      (snd_vu),
    .snd_peak                    (snd_peak),
    .debug_bus                   (debug_bus),
    .debug_view                  (debug_view),
    .personality_valid           (top_personality_valid),
    .personality_set_id          (),
    .personality_control_id      (top_personality_control_id),
    .personality_region_table_id (),
    .payload_crc32               (),
    .payload_count               (),
    .ss_do_save                  (ss_save),
    .ss_do_restore               (ss_load),
    .ss_busy                     (ss_busy),
    .ss_format_valid             (ss_format_valid),
    .ss_write_start              (ss_stream_save),
    .ss_read_start               (ss_stream_load),
    .ss_active                   (ss_active),
    .ss_state_out                (ss_state_debug),
    .ss_data                     (ssb[0].data),
    .ss_addr                     (ssb[0].addr),
    .ss_select                   (ssb[0].select),
    .ss_write                    (ssb[0].write),
    .ss_read                     (ssb[0].read),
    .ss_query                    (ssb[0].query),
    .ss_data_out                 (ssb[0].data_out),
    .ss_ack                      (ssb[0].ack)
);
