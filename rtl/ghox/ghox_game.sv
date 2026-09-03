// Framework-facing Ghox integration shell.
//
// The protected JTFrame downloader supplies index 0 through ioctl_* but only
// retains two bytes of index 1 as core_mod/game_vol. Ghox therefore observes
// the root hps_* stream directly for its strict 64-byte GHXM identity record.
// No protected framework source is changed.
module ghox_game #(
    parameter integer AW = 22
) (
    input  logic         rst,
    input  logic         cold_rst,
    input  logic         clk,

    output logic         pxl2_cen,
    output logic         pxl_cen,
    output logic [7:0]   red,
    output logic [7:0]   green,
    output logic [7:0]   blue,
    output logic         LHBL,
    output logic         LVBL,
    output logic         HS,
    output logic         VS,

    // JTFrame game inputs are active low. Bit order is
    // right, left, down, up, button 1, button 2.
    input  logic [5:0]   joystick1,
    input  logic [5:0]   joystick2,
    input  logic [3:0]   cab_1p,
    input  logic [3:0]   coin,
    input  logic         service,
    input  logic         tilt,
    input  logic         dip_test,
    input  logic         dip_pause,
    inout  wire          dip_flip,
    input  logic [31:0]  dipsw,
    input  logic [127:0] status,
    input  logic [8:0]   spinner_1p,
    input  logic [8:0]   spinner_2p,

    input  logic [26:0]  ioctl_addr,
    input  logic [7:0]   ioctl_dout,
    input  logic         ioctl_wr,
    input  logic         ioctl_rom,
    output logic [7:0]   ioctl_din,
    output logic         dwnld_busy,

    // Raw HPS view used for the index-1 GHXM ABI and Ghox-local high-score
    // transport. Index 4 is kept out of the protected JTFrame downloader.
    input  logic         hps_download,
    input  logic [15:0]  hps_index,
    input  logic         hps_wr,
    input  logic         hps_rd,
    input  logic [26:0]  hps_addr,
    input  logic [7:0]   hps_dout,
    input  logic         hs_config_download,
    input  logic         hs_nvram_download,
    input  logic         hs_nvram_upload,
    output logic [7:0]   hs_nvram_q,
    output logic         hs_nvram_wait,
    output logic         hs_dirty,
    output logic         hs_ready,
    output logic         hs_active,

    input  logic [15:0]  data_read,
    output logic [AW-1:0] ba0_addr,
    output logic [AW-1:0] ba1_addr,
    output logic [AW-1:0] ba2_addr,
    output logic [AW-1:0] ba3_addr,
    output logic [3:0]   ba_rd,
    output logic [3:0]   ba_wr,
    input  logic [3:0]   ba_dst,
    input  logic [3:0]   ba_dok,
    input  logic [3:0]   ba_rdy,
    input  logic [3:0]   ba_ack,
    output logic [15:0]  ba0_din,
    output logic [1:0]   ba0_dsn,
    output logic [15:0]  ba1_din,
    output logic [1:0]   ba1_dsn,
    output logic [15:0]  ba2_din,
    output logic [1:0]   ba2_dsn,
    output logic [15:0]  ba3_din,
    output logic [1:0]   ba3_dsn,

    output logic [1:0]   prog_ba,
    input  logic         prog_rdy,
    input  logic         prog_ack,
    input  logic         prog_dok,
    input  logic         prog_dst,
    output logic [15:0]  prog_data,
    output logic [AW-1:0] prog_addr,
    output logic         prog_rd,
    output logic         prog_we,
    output logic [1:0]   prog_mask,

    output logic signed [15:0] snd_left,
    output logic signed [15:0] snd_right,
    output logic         sample,
    input  logic [5:0]   snd_en,
    input  logic [7:0]   snd_vol,
    output logic [5:0]   snd_vu,
    output logic         snd_peak,

    output logic [7:0]   debug_bus,
    output logic [7:0]   debug_view,
    output logic         personality_valid,
    output logic [7:0]   personality_set_id,
    output logic [7:0]   personality_control_id,
    output logic [7:0]   personality_region_table_id,
    output logic [31:0]  payload_crc32,
    output logic [26:0]  payload_count,

    input  logic         ss_do_save,
    input  logic         ss_do_restore,
    input  logic         ss_busy,
    input  logic         ss_format_valid,
    output logic         ss_write_start,
    output logic         ss_read_start,
    output logic         ss_active,
    output logic [3:0]   ss_state_out,
    input  logic [63:0]  ss_data,
    input  logic [31:0]  ss_addr,
    input  logic [7:0]   ss_select,
    input  logic         ss_write,
    input  logic         ss_read,
    input  logic         ss_query,
    output logic [63:0]  ss_data_out,
    output logic         ss_ack
);

logic loader_busy;
logic payload_begin;
logic payload_complete;
logic loader_accepted;
logic loader_range_error;
logic loader_order_error;
logic loader_overflow_error;
logic [26:0] loader_last_addr;

ghox_rom_loader #(.AW(AW)) u_rom_loader (
    .clk                (clk),
    // The game reset is asserted throughout a download; only cold reset may
    // reset the loader and personality parser.
    .rst                (cold_rst),
    .ioctl_rom_i        (ioctl_rom),
    .ioctl_addr_i       (ioctl_addr),
    .ioctl_data_i       (ioctl_dout),
    .ioctl_wr_i         (ioctl_wr),
    .dwnld_busy_o       (loader_busy),
    .prog_ba_o          (prog_ba),
    .prog_addr_o        (prog_addr),
    .prog_data_o        (prog_data),
    .prog_mask_o        (prog_mask),
    .prog_rd_o          (prog_rd),
    .prog_we_o          (prog_we),
    .prog_rdy_i         (prog_rdy),
    .prog_ack_i         (prog_ack),
    .payload_begin_o    (payload_begin),
    .payload_complete_o (payload_complete),
    .payload_count_o    (payload_count),
    .payload_crc32_o    (payload_crc32),
    .accepted_o         (loader_accepted),
    .range_error_o      (loader_range_error),
    .order_error_o      (loader_order_error),
    .overflow_error_o   (loader_overflow_error),
    .last_addr_o        (loader_last_addr)
);

wire metadata_active = hps_download && hps_index[5:0] == 6'd1;
wire metadata_complete;
wire metadata_error;
wire [7:0] personality_abi_version;
wire [31:0] personality_payload_length;
wire [31:0] personality_payload_crc32;
wire [255:0] personality_payload_sha256;

ghox_personality u_personality (
    .clk                 (clk),
    .rst                 (cold_rst),
    .payload_begin_i     (payload_begin),
    .payload_complete_i  (payload_complete),
    .payload_count_i     (payload_count),
    .payload_crc32_i     (payload_crc32),
    .metadata_active_i   (metadata_active),
    .metadata_wr_i       (hps_wr),
    .metadata_addr_i     (hps_addr),
    .metadata_data_i     (hps_dout),
    .valid_o             (personality_valid),
    .abi_version_o       (personality_abi_version),
    .set_id_o            (personality_set_id),
    .control_id_o        (personality_control_id),
    .region_table_id_o   (personality_region_table_id),
    .payload_length_o    (personality_payload_length),
    .payload_crc32_o     (personality_payload_crc32),
    .payload_sha256_o    (personality_payload_sha256),
    .metadata_complete_o (metadata_complete),
    .metadata_error_o    (metadata_error)
);

assign ioctl_din = 8'h00;
assign dwnld_busy = loader_busy || metadata_active;

// JTFrame generates game_rst on the falling edge of the game clock. Capture
// it once locally so the core's synchronous reset fanout launches on the same
// rising-edge domain as every Ghox state owner. The framework holds game_rst
// for hundreds of clocks, so the one-cycle assertion/deassertion latency is
// immaterial while eliminating half-cycle reset-distribution paths.
logic core_rst = 1'b1;
always_ff @(posedge clk)
    core_rst <= rst;

wire board_reset = core_rst || loader_busy || metadata_active ||
                   !personality_valid;

// JTFrame's game-facing signals are active-low, while MAME's Ghox IN1/IN2/SYS
// bytes are active-high (00 idle).  Convert polarity once here and leave the
// unused upper joystick bits and system bit 7 inactive (low).
wire [7:0] p1_input = {
    2'b00, ~joystick1[5], ~joystick1[4],
    ~joystick1[0], ~joystick1[1], ~joystick1[2], ~joystick1[3]
};
wire [7:0] p2_input = {
    2'b00, ~joystick2[5], ~joystick2[4],
    ~joystick2[0], ~joystick2[1], ~joystick2[2], ~joystick2[3]
};
wire [7:0] system_input = {
    1'b0, ~cab_1p[1], ~cab_1p[0], ~coin[1], ~coin[0],
    ~dip_test, ~tilt, ~service
};

wire main_rom_req;
wire [16:0] main_rom_addr;
wire [15:0] main_rom_data;
wire main_rom_ok;
wire sound_rom_req;
wire [14:0] sound_rom_addr;
wire [7:0] sound_rom_data;
wire sound_rom_ok;
wire tile_gfx_req;
wire [18:0] tile_gfx_addr;
wire [15:0] tile_gfx_data;
wire tile_gfx_ok;
wire object_gfx_req;
wire [18:0] object_gfx_addr;
wire [15:0] object_gfx_data;
wire object_gfx_ok;
wire bank0_rom_rd;
wire graphics_rom_rd;

jtframe_rom_2slots #(
    .SDRAMW        (AW),
    .SLOT0_DW      (16),
    .SLOT1_DW      (8),
    .SLOT0_AW      (17),
    .SLOT1_AW      (15),
    .SLOT0_LATCH   (0),
    .SLOT1_LATCH   (0),
    .SLOT0_OKLATCH (0),
    .SLOT1_OKLATCH (0),
    .SLOT0_OFFSET  ({AW{1'b0}}),
    .SLOT1_OFFSET  (22'h020000)
) u_program_sound_rom (
    .rst        (board_reset),
    .clk        (clk),
    .slot0_addr (main_rom_addr),
    .slot1_addr (sound_rom_addr),
    .slot0_dout (main_rom_data),
    .slot1_dout (sound_rom_data),
    .slot0_cs   (main_rom_req),
    .slot1_cs   (sound_rom_req),
    .slot0_ok   (main_rom_ok),
    .slot1_ok   (sound_rom_ok),
    .sdram_ack  (ba_ack[0]),
    .sdram_rd   (bank0_rom_rd),
    .sdram_addr (ba0_addr),
    .data_dst   (ba_dst[0]),
    .data_rdy   (ba_rdy[0]),
    .data_read  (data_read)
);

jtframe_rom_2slots #(
    .SDRAMW        (AW),
    .SLOT0_DW      (16),
    .SLOT1_DW      (16),
    .SLOT0_AW      (19),
    .SLOT1_AW      (19),
    .SLOT0_LATCH   (0),
    .SLOT1_LATCH   (0),
    .SLOT0_OKLATCH (0),
    .SLOT1_OKLATCH (0)
) u_graphics_rom (
    .rst        (board_reset),
    .clk        (clk),
    .slot0_addr (tile_gfx_addr),
    .slot1_addr (object_gfx_addr),
    .slot0_dout (tile_gfx_data),
    .slot1_dout (object_gfx_data),
    .slot0_cs   (tile_gfx_req),
    .slot1_cs   (object_gfx_req),
    .slot0_ok   (tile_gfx_ok),
    .slot1_ok   (object_gfx_ok),
    .sdram_ack  (ba_ack[1]),
    .sdram_rd   (graphics_rom_rd),
    .sdram_addr (ba1_addr),
    .data_dst   (ba_dst[1]),
    .data_rdy   (ba_rdy[1]),
    .data_read  (data_read)
);

assign ba2_addr = {AW{1'b0}};
assign ba3_addr = {AW{1'b0}};
assign ba_rd = {2'b00, graphics_rom_rd, bank0_rom_rd};
assign ba_wr = 4'b0000;
assign ba0_din = 16'h0000;
assign ba1_din = 16'h0000;
assign ba2_din = 16'h0000;
assign ba3_din = 16'h0000;
assign ba0_dsn = 2'b11;
assign ba1_dsn = 2'b11;
assign ba2_dsn = 2'b11;
assign ba3_dsn = 2'b11;

wire [9:0] board_hcnt;
wire [8:0] board_vcnt;
wire board_frame_tick;
wire board_irq4;
wire [1:0] video_deadline_miss;
wire tile_gfx_invalid;
wire object_gfx_invalid;
wire [31:0] main_bus_count;
wire [31:0] main_gp_access_count;
wire [31:0] main_palette_write_count;
wire [31:0] sound_shared_write_count;
wire [31:0] sound_ym_write_count;
wire board_main_cpu_bus_active;
wire board_main_cpu_rw;
wire [23:0] board_main_cpu_addr;
wire [15:0] board_main_cpu_dout;
wire board_main_cpu_ack;
wire board_main_cpu_iack;
wire board_main_gp_idle;
wire [7:0] board_main_coin_control;
wire [1:0] board_main_wram_we;
wire board_video_line_ready;
wire board_video_line_start;
wire board_video_line_commit;
wire [8:0] board_video_line_target_y;
wire board_video_line_target_epoch;
wire board_video_epoch;
wire [1:0] board_video_engine_busy;
wire [1:0] board_video_engine_done;
wire [15:0] board_video_tile_cycles;
wire [15:0] board_video_object_cycles;
wire [8:0] board_video_tile_line_y;
wire [8:0] board_video_object_line_y;
wire [1:0] board_video_line_epoch;
wire [1:0] board_video_line_valid;
wire board_sound_idle;
wire board_sound_restore_done;
wire board_sound_restore_failed;
wire board_video_idle;
wire board_ss_ack;
wire [63:0] board_ss_data;
wire ss_irq7;
wire ss_main_override;
wire ss_main_reset;
wire ss_main_run;
wire ss_owner_hold;
wire ss_restore_enable;
wire ss_restore_commit;
wire ss_restore_irq4;
wire [7:0] ss_restore_coin_control;
wire [63:0] ss_reset_vector;
wire ss_sound_reset;
wire ss_video_reset;
wire ss_video_hide;
wire [7:0] board_red;
wire [7:0] board_green;
wire [7:0] board_blue;
wire signed [15:0] board_snd_left;
wire signed [15:0] board_snd_right;

wire        hs_hold_request;
logic       hs_hold_ack = 1'b0;
wire        hs_ram_owned;
wire [12:0] hs_ram_addr;
wire [1:0]  hs_ram_we;
wire [15:0] hs_ram_data;
wire [15:0] hs_ram_q;
wire hs_cpu_run = !hs_hold_request ||
                  (board_main_cpu_bus_active && !hs_hold_ack);

always_ff @(posedge clk) begin
    if (board_reset || !hs_hold_request || ss_active)
        hs_hold_ack <= 1'b0;
    else if (!board_main_cpu_bus_active)
        hs_hold_ack <= 1'b1;
end

ghox_savestate u_savestate (
    .clk                    (clk),
    .rst                    (board_reset),
    .dwnld_busy_i           (dwnld_busy),
    .do_save_i              (ss_do_save),
    .do_restore_i           (ss_do_restore),
    .stream_busy_i          (ss_busy),
    .root_format_valid_i    (ss_format_valid),
    .write_start_o          (ss_write_start),
    .read_start_o           (ss_read_start),
    .active_o               (ss_active),
    .state_o                (ss_state_out),
    .video_hide_o           (ss_video_hide),
    .abi_version_i          (personality_abi_version),
    .set_id_i               (personality_set_id),
    .control_id_i           (personality_control_id),
    .region_table_id_i      (personality_region_table_id),
    .payload_length_i       (personality_payload_length),
    .payload_crc32_i        (personality_payload_crc32),
    .payload_sha256_i       (personality_payload_sha256),
    .vcnt_i                 (board_vcnt),
    .frame_tick_i           (board_frame_tick),
    .main_bus_active_i      (board_main_cpu_bus_active),
    .main_rw_i              (board_main_cpu_rw),
    .main_addr_i            (board_main_cpu_addr),
    .main_dout_i            (board_main_cpu_dout),
    .main_ack_i             (board_main_cpu_ack),
    .main_iack_i            (board_main_cpu_iack),
    .main_gp_idle_i         (board_main_gp_idle),
    .sound_idle_i           (board_sound_idle),
    .sound_restore_done_i   (board_sound_restore_done),
    .sound_restore_failed_i (board_sound_restore_failed),
    .video_idle_i           (board_video_idle),
    .irq4_i                 (board_irq4),
    .coin_control_i         (board_main_coin_control),
    .irq7_o                 (ss_irq7),
    .main_override_o        (ss_main_override),
    .main_reset_o           (ss_main_reset),
    .main_run_o             (ss_main_run),
    .owner_hold_o           (ss_owner_hold),
    .restore_enable_o       (ss_restore_enable),
    .restore_commit_o       (ss_restore_commit),
    .restore_irq4_o         (ss_restore_irq4),
    .restore_coin_control_o (ss_restore_coin_control),
    .reset_vector_o         (ss_reset_vector),
    .sound_reset_o          (ss_sound_reset),
    .video_reset_o          (ss_video_reset),
    .ss_data_i              (ss_data),
    .ss_addr_i              (ss_addr),
    .ss_select_i            (ss_select),
    .ss_write_i             (ss_write),
    .ss_read_i              (ss_read),
    .ss_query_i             (ss_query),
    .owner_ss_data_i        (board_ss_data),
    .owner_ss_ack_i         (board_ss_ack),
    .ss_data_o              (ss_data_out),
    .ss_ack_o               (ss_ack)
);

ghox_highscore u_highscore (
    .clk                (clk),
    .reset              (cold_rst),
    .cpu_reset          (board_reset),
    .rom_set_id         (personality_set_id),
    .rom_identity_valid (personality_valid),
    .config_download    (hs_config_download),
    .config_wr          (hps_wr),
    .config_addr        (hps_addr),
    .config_data        (hps_dout),
    .nvram_download     (hs_nvram_download),
    .nvram_upload       (hs_nvram_upload),
    .nvram_wr           (hps_wr),
    .nvram_rd           (hps_rd),
    .nvram_addr         (hps_addr),
    .nvram_data         (hps_dout),
    .nvram_q            (hs_nvram_q),
    .nvram_wait         (hs_nvram_wait),
    .ss_active          (ss_active),
    .ss_restore_commit  (ss_restore_commit),
    .normal_ram_addr    (board_main_cpu_addr[13:1]),
    .normal_ram_we      (board_main_wram_we),
    .normal_ram_data    (board_main_cpu_dout),
    .hold_request       (hs_hold_request),
    .hold_ack           (hs_hold_ack),
    .ram_owned          (hs_ram_owned),
    .ram_addr           (hs_ram_addr),
    .ram_we             (hs_ram_we),
    .ram_data           (hs_ram_data),
    .ram_q              (hs_ram_q),
    .dirty              (hs_dirty),
    .ready              (hs_ready),
    .active             (hs_active),
    .config_valid       (),
    .active_profile     ()
);

ghox_board u_board (
    .clk                        (clk),
    .rst                        (board_reset),
    .run_i                      (dip_pause),
    .spinner_personality_i      (personality_control_id == 8'd1),
    .spinner_1p_i               (spinner_1p),
    .spinner_2p_i               (spinner_2p),
    .p1_i                       (p1_input),
    .p2_i                       (p2_input),
    .system_i                   (system_input),
    .dsw_a_i                    (dipsw[7:0]),
    .dsw_b_i                    (dipsw[15:8]),
    .region_i                   (dipsw[23:20]),
    .fm_enable_i                (!status[9]),
    .ss_irq_i                   (ss_irq7),
    .ss_override_i              (ss_main_override),
    .ss_main_reset_i            (ss_main_reset),
    .ss_cpu_run_i               (ss_main_run && hs_cpu_run),
    .ss_hold_i                  (ss_owner_hold),
    .ss_restore_enable_i        (ss_restore_enable),
    .ss_restore_commit_i        (ss_restore_commit),
    .ss_restore_irq4_i          (ss_restore_irq4),
    .ss_restore_coin_control_i  (ss_restore_coin_control),
    .ss_reset_vector_i          (ss_reset_vector),
    .ss_sound_reset_i           (ss_sound_reset),
    .ss_video_reset_i           (ss_video_reset),
    .ss_data_i                  (ss_data),
    .ss_addr_i                  (ss_addr),
    .ss_select_i                (ss_select),
    .ss_write_i                 (ss_write),
    .ss_read_i                  (ss_read),
    .ss_query_i                 (ss_query),
    .ss_data_o                  (board_ss_data),
    .ss_ack_o                   (board_ss_ack),
    .hs_ram_owned_i             (hs_ram_owned),
    .hs_ram_addr_i              (hs_ram_addr),
    .hs_ram_we_i                (hs_ram_we),
    .hs_ram_data_i              (hs_ram_data),
    .hs_ram_q_o                 (hs_ram_q),
    .main_wram_we_o             (board_main_wram_we),
    .main_rom_req_o             (main_rom_req),
    .main_rom_addr_o            (main_rom_addr),
    .main_rom_data_i            (main_rom_data),
    .main_rom_ok_i              (main_rom_ok),
    .sound_rom_req_o            (sound_rom_req),
    .sound_rom_addr_o           (sound_rom_addr),
    .sound_rom_data_i           (sound_rom_data),
    .sound_rom_ok_i             (sound_rom_ok),
    .tile_gfx_req_o             (tile_gfx_req),
    .tile_gfx_addr_o            (tile_gfx_addr),
    .tile_gfx_data_i            (tile_gfx_data),
    .tile_gfx_ok_i              (tile_gfx_ok),
    .object_gfx_req_o           (object_gfx_req),
    .object_gfx_addr_o          (object_gfx_addr),
    .object_gfx_data_i          (object_gfx_data),
    .object_gfx_ok_i            (object_gfx_ok),
    .pxl2_cen_o                 (pxl2_cen),
    .pxl_cen_o                  (pxl_cen),
    .red_o                      (board_red),
    .green_o                    (board_green),
    .blue_o                     (board_blue),
    .lhbl_o                     (LHBL),
    .lvbl_o                     (LVBL),
    .hs_o                       (HS),
    .vs_o                       (VS),
    .audio_left_o               (board_snd_left),
    .audio_right_o              (board_snd_right),
    .sample_o                   (sample),
    .hcnt_o                     (board_hcnt),
    .vcnt_o                     (board_vcnt),
    .frame_tick_o               (board_frame_tick),
    .irq4_o                     (board_irq4),
    .video_deadline_miss_o      (video_deadline_miss),
    .tile_gfx_invalid_o         (tile_gfx_invalid),
    .object_gfx_invalid_o       (object_gfx_invalid),
    .main_bus_count_o           (main_bus_count),
    .main_gp_access_count_o     (main_gp_access_count),
    .main_palette_write_count_o (main_palette_write_count),
    .sound_shared_write_count_o (sound_shared_write_count),
    .sound_ym_write_count_o     (sound_ym_write_count),
    .main_cpu_bus_active_o      (board_main_cpu_bus_active),
    .main_cpu_rw_o              (board_main_cpu_rw),
    .main_cpu_addr_o            (board_main_cpu_addr),
    .main_cpu_dout_o            (board_main_cpu_dout),
    .main_cpu_ack_o             (board_main_cpu_ack),
    .main_cpu_iack_o            (board_main_cpu_iack),
    .main_gp_idle_o             (board_main_gp_idle),
    .main_coin_control_o        (board_main_coin_control),
    .video_line_ready_o         (board_video_line_ready),
    .video_line_start_o         (board_video_line_start),
    .video_line_commit_o        (board_video_line_commit),
    .video_line_target_y_o      (board_video_line_target_y),
    .video_line_target_epoch_o  (board_video_line_target_epoch),
    .video_epoch_o              (board_video_epoch),
    .video_engine_busy_o        (board_video_engine_busy),
    .video_engine_done_o        (board_video_engine_done),
    .video_tile_cycles_o        (board_video_tile_cycles),
    .video_object_cycles_o      (board_video_object_cycles),
    .video_tile_line_y_o        (board_video_tile_line_y),
    .video_object_line_y_o      (board_video_object_line_y),
    .video_line_epoch_o         (board_video_line_epoch),
    .video_line_valid_o         (board_video_line_valid),
    .sound_restore_done_o       (board_sound_restore_done),
    .sound_restore_failed_o     (board_sound_restore_failed),
    .sound_idle_o               (board_sound_idle),
    .video_idle_o               (board_video_idle)
);

assign red = ss_video_hide ? 8'd0 : board_red;
assign green = ss_video_hide ? 8'd0 : board_green;
assign blue = ss_video_hide ? 8'd0 : board_blue;
assign snd_left = ss_active ? 16'sd0 : board_snd_left;
assign snd_right = ss_active ? 16'sd0 : board_snd_right;

assign dip_flip = 1'b0;
assign snd_vu = 6'd0;
assign snd_peak = 1'b0;

assign debug_bus = dwnld_busy ? {
    loader_range_error, loader_order_error, loader_overflow_error,
    metadata_error, loader_accepted, prog_we, personality_valid, 1'b0
} : main_bus_count[15:8];
assign debug_view = dwnld_busy ? loader_last_addr[7:0] : {
    |video_deadline_miss, tile_gfx_invalid, object_gfx_invalid,
    board_irq4, personality_control_id[1:0], board_frame_tick,
    metadata_complete
};

// Framework compatibility/status inputs that do not alter TP-021 behavior.
wire unused_inputs = &{1'b0, ba_dok, prog_dok, prog_dst, snd_en, snd_vol,
                      personality_abi_version,
                      personality_payload_length,
                      personality_payload_crc32,
                      personality_payload_sha256[0],
                      board_hcnt[0], board_vcnt[0], main_gp_access_count[0],
                      sound_shared_write_count[0], sound_ym_write_count[0],
                      ss_state_out[0]};

endmodule
