// TP-021 board integration independent of the MiSTer framework boundary.
//
// All logic runs in one 94.5 MHz domain. Pixel, YM2151, and HD647180 rates
// are clock enables; no fabric-generated clocks are used. ROM ports hold
// their request/address until the corresponding *_ok input acknowledges it.
module ghox_board (
    input  logic         clk,
    input  logic         rst,
    input  logic         run_i,
    input  logic         spinner_personality_i,

    input  logic [8:0]   spinner_1p_i,
    input  logic [8:0]   spinner_2p_i,
    input  logic [7:0]   p1_i,
    input  logic [7:0]   p2_i,
    input  logic [7:0]   system_i,
    input  logic [7:0]   dsw_a_i,
    input  logic [7:0]   dsw_b_i,
    input  logic [3:0]   region_i,
    input  logic         fm_enable_i,

    input  logic         ss_irq_i,
    input  logic         ss_override_i,
    input  logic         ss_main_reset_i,
    input  logic         ss_cpu_run_i,
    input  logic         ss_hold_i,
    input  logic         ss_restore_enable_i,
    input  logic         ss_restore_commit_i,
    input  logic         ss_restore_irq4_i,
    input  logic [7:0]   ss_restore_coin_control_i,
    input  logic [63:0]  ss_reset_vector_i,
    input  logic         ss_sound_reset_i,
    input  logic         ss_video_reset_i,
    input  logic [63:0]  ss_data_i,
    input  logic [31:0]  ss_addr_i,
    input  logic [7:0]   ss_select_i,
    input  logic         ss_write_i,
    input  logic         ss_read_i,
    input  logic         ss_query_i,
    output logic [63:0]  ss_data_o,
    output logic         ss_ack_o,

    input  logic         hs_ram_owned_i,
    input  logic [12:0]  hs_ram_addr_i,
    input  logic [1:0]   hs_ram_we_i,
    input  logic [15:0]  hs_ram_data_i,
    output logic [15:0]  hs_ram_q_o,
    output logic [1:0]   main_wram_we_o,

    output logic         main_rom_req_o,
    output logic [16:0]  main_rom_addr_o,
    input  logic [15:0]  main_rom_data_i,
    input  logic         main_rom_ok_i,

    output logic         sound_rom_req_o,
    output logic [14:0]  sound_rom_addr_o,
    input  logic [7:0]   sound_rom_data_i,
    input  logic         sound_rom_ok_i,

    output logic         tile_gfx_req_o,
    output logic [18:0]  tile_gfx_addr_o,
    input  logic [15:0]  tile_gfx_data_i,
    input  logic         tile_gfx_ok_i,
    output logic         object_gfx_req_o,
    output logic [18:0]  object_gfx_addr_o,
    input  logic [15:0]  object_gfx_data_i,
    input  logic         object_gfx_ok_i,

    output logic         pxl2_cen_o,
    output logic         pxl_cen_o,
    output logic [7:0]   red_o,
    output logic [7:0]   green_o,
    output logic [7:0]   blue_o,
    output logic         lhbl_o,
    output logic         lvbl_o,
    output logic         hs_o,
    output logic         vs_o,

    output logic signed [15:0] audio_left_o,
    output logic signed [15:0] audio_right_o,
    output logic         sample_o,

    output logic [9:0]   hcnt_o,
    output logic [8:0]   vcnt_o,
    output logic         frame_tick_o,
    output logic         irq4_o,
    output logic [1:0]   video_deadline_miss_o,
    output logic         tile_gfx_invalid_o,
    output logic         object_gfx_invalid_o,
    output logic [31:0]  main_bus_count_o,
    output logic [31:0]  main_gp_access_count_o,
    output logic [31:0]  main_palette_write_count_o,
    output logic [31:0]  sound_shared_write_count_o,
    output logic [31:0]  sound_ym_write_count_o,
    output logic         main_cpu_bus_active_o,
    output logic         main_cpu_rw_o,
    output logic [23:0]  main_cpu_addr_o,
    output logic [15:0]  main_cpu_dout_o,
    output logic         main_cpu_ack_o,
    output logic         main_cpu_iack_o,
    output logic         main_gp_idle_o,
    output logic [7:0]   main_coin_control_o,
    output logic         video_line_ready_o,
    output logic         video_line_start_o,
    output logic         video_line_commit_o,
    output logic [8:0]   video_line_target_y_o,
    output logic         video_line_target_epoch_o,
    output logic         video_epoch_o,
    output logic [1:0]   video_engine_busy_o,
    output logic [1:0]   video_engine_done_o,
    output logic [15:0]  video_tile_cycles_o,
    output logic [15:0]  video_object_cycles_o,
    output logic [8:0]   video_tile_line_y_o,
    output logic [8:0]   video_object_line_y_o,
    output logic [1:0]   video_line_epoch_o,
    output logic [1:0]   video_line_valid_o,
    output logic         sound_restore_done_o,
    output logic         sound_restore_failed_o,
    output logic         sound_idle_o,
    output logic         video_idle_o
);

logic [9:0] hcnt;
logic [8:0] vcnt;
logic video_epoch;
logic sound_cpu_cen;
logic opm_tick;
logic line_start;
logic line_commit;
logic [8:0] line_target_y;
logic line_target_epoch;
logic object_buffer_start;
logic irq4_start;
logic gp_status;

assign hcnt_o = hcnt;
assign vcnt_o = vcnt;

ghox_timing u_timing (
    .clk                   (clk),
    .rst                   (rst),
    .pixel2_cen_o          (pxl2_cen_o),
    .pixel_cen_o           (pxl_cen_o),
    .opm_cen_o             (opm_tick),
    .sound_cpu_cen_o       (sound_cpu_cen),
    .hcnt_o                (hcnt),
    .vcnt_o                (vcnt),
    .video_epoch_o         (video_epoch),
    .line_start_o          (line_start),
    .line_commit_o         (line_commit),
    .line_target_y_o       (line_target_y),
    .line_target_epoch_o   (line_target_epoch),
    .object_buffer_start_o (object_buffer_start),
    .irq4_start_o          (irq4_start),
    .gp_status_o           (gp_status),
    .frame_tick_o          (frame_tick_o)
);

logic signed [7:0] p1_spinner_delta;
logic signed [7:0] p2_spinner_delta;
logic p1_analog_read;
logic p2_analog_read;
logic main_cpu_cen;
logic spinner_state_load;
logic [7:0] spinner_p1_current_in;
logic [7:0] spinner_p1_consumed_in;
logic spinner_p1_last_toggle_in;
logic spinner_p1_pending_in;
logic spinner_p1_physical_owner_in;
logic [17:0] spinner_p1_fallback_phase_in;
logic [18:0] spinner_p1_physical_holdoff_in;
logic [7:0] spinner_p2_current_in;
logic [7:0] spinner_p2_consumed_in;
logic spinner_p2_last_toggle_in;
logic spinner_p2_pending_in;
logic spinner_p2_physical_owner_in;
logic [17:0] spinner_p2_fallback_phase_in;
logic [18:0] spinner_p2_physical_holdoff_in;
logic [7:0] spinner_p1_current_out;
logic [7:0] spinner_p1_consumed_out;
logic spinner_p1_last_toggle_out;
logic spinner_p1_pending_out;
logic spinner_p1_physical_owner_out;
logic [17:0] spinner_p1_fallback_phase_out;
logic [18:0] spinner_p1_physical_holdoff_out;
logic [7:0] spinner_p2_current_out;
logic [7:0] spinner_p2_consumed_out;
logic spinner_p2_last_toggle_out;
logic spinner_p2_pending_out;
logic spinner_p2_physical_owner_out;
logic [17:0] spinner_p2_fallback_phase_out;
logic [18:0] spinner_p2_physical_holdoff_out;
logic [63:0] spinner_ss_data;
logic spinner_ss_ack;

ghox_spinner u_spinner_1p (
    .clk                         (clk),
    .rst                         (rst),
    .ce_cpu                      (main_cpu_cen),
    .spinner_mode                (spinner_personality_i),
    .physical_enable             (1'b1),
    .fallback_enable             (1'b0),
    .host_delta                  (spinner_1p_i[7:0]),
    .host_toggle                 (spinner_1p_i[8]),
    .fallback_step               (1'b0),
    .fallback_right              (1'b0),
    .cpu_read_accept             (p1_analog_read),
    .read_valid                  (),
    .read_delta                  (),
    .cpu_delta                   (p1_spinner_delta),
    .state_load                  (spinner_state_load),
    .state_current_in            (spinner_p1_current_in),
    .state_consumed_in           (spinner_p1_consumed_in),
    .state_last_toggle_in        (spinner_p1_last_toggle_in),
    .state_pending_in            (spinner_p1_pending_in),
    .state_physical_owner_in     (spinner_p1_physical_owner_in),
    .state_fallback_phase_in     (spinner_p1_fallback_phase_in),
    .state_physical_holdoff_in   (spinner_p1_physical_holdoff_in),
    .state_current_out           (spinner_p1_current_out),
    .state_consumed_out          (spinner_p1_consumed_out),
    .state_last_toggle_out       (spinner_p1_last_toggle_out),
    .state_pending_out           (spinner_p1_pending_out),
    .state_physical_owner_out    (spinner_p1_physical_owner_out),
    .state_fallback_phase_out    (spinner_p1_fallback_phase_out),
    .state_physical_holdoff_out  (spinner_p1_physical_holdoff_out)
);

ghox_spinner u_spinner_2p (
    .clk                         (clk),
    .rst                         (rst),
    .ce_cpu                      (main_cpu_cen),
    .spinner_mode                (spinner_personality_i),
    .physical_enable             (1'b1),
    .fallback_enable             (1'b0),
    .host_delta                  (spinner_2p_i[7:0]),
    .host_toggle                 (spinner_2p_i[8]),
    .fallback_step               (1'b0),
    .fallback_right              (1'b0),
    .cpu_read_accept             (p2_analog_read),
    .read_valid                  (),
    .read_delta                  (),
    .cpu_delta                   (p2_spinner_delta),
    .state_load                  (spinner_state_load),
    .state_current_in            (spinner_p2_current_in),
    .state_consumed_in           (spinner_p2_consumed_in),
    .state_last_toggle_in        (spinner_p2_last_toggle_in),
    .state_pending_in            (spinner_p2_pending_in),
    .state_physical_owner_in     (spinner_p2_physical_owner_in),
    .state_fallback_phase_in     (spinner_p2_fallback_phase_in),
    .state_physical_holdoff_in   (spinner_p2_physical_holdoff_in),
    .state_current_out           (spinner_p2_current_out),
    .state_consumed_out          (spinner_p2_consumed_out),
    .state_last_toggle_out       (spinner_p2_last_toggle_out),
    .state_pending_out           (spinner_p2_pending_out),
    .state_physical_owner_out    (spinner_p2_physical_owner_out),
    .state_fallback_phase_out    (spinner_p2_fallback_phase_out),
    .state_physical_holdoff_out  (spinner_p2_physical_holdoff_out)
);

ghox_spinner_state u_spinner_state (
    .clk                      (clk),
    .rst                      (rst),
    .restore_enable_i         (ss_restore_enable_i),
    .restore_commit_i         (ss_restore_commit_i),
    .p1_current_i             (spinner_p1_current_out),
    .p1_consumed_i            (spinner_p1_consumed_out),
    .p1_last_toggle_i         (spinner_p1_last_toggle_out),
    .p1_pending_i             (spinner_p1_pending_out),
    .p1_physical_owner_i      (spinner_p1_physical_owner_out),
    .p1_fallback_phase_i      (spinner_p1_fallback_phase_out),
    .p1_physical_holdoff_i    (spinner_p1_physical_holdoff_out),
    .p2_current_i             (spinner_p2_current_out),
    .p2_consumed_i            (spinner_p2_consumed_out),
    .p2_last_toggle_i         (spinner_p2_last_toggle_out),
    .p2_pending_i             (spinner_p2_pending_out),
    .p2_physical_owner_i      (spinner_p2_physical_owner_out),
    .p2_fallback_phase_i      (spinner_p2_fallback_phase_out),
    .p2_physical_holdoff_i    (spinner_p2_physical_holdoff_out),
    .state_load_o             (spinner_state_load),
    .p1_current_o             (spinner_p1_current_in),
    .p1_consumed_o            (spinner_p1_consumed_in),
    .p1_last_toggle_o         (spinner_p1_last_toggle_in),
    .p1_pending_o             (spinner_p1_pending_in),
    .p1_physical_owner_o      (spinner_p1_physical_owner_in),
    .p1_fallback_phase_o      (spinner_p1_fallback_phase_in),
    .p1_physical_holdoff_o    (spinner_p1_physical_holdoff_in),
    .p2_current_o             (spinner_p2_current_in),
    .p2_consumed_o            (spinner_p2_consumed_in),
    .p2_last_toggle_o         (spinner_p2_last_toggle_in),
    .p2_pending_o             (spinner_p2_pending_in),
    .p2_physical_owner_o      (spinner_p2_physical_owner_in),
    .p2_fallback_phase_o      (spinner_p2_fallback_phase_in),
    .p2_physical_holdoff_o    (spinner_p2_physical_holdoff_in),
    .ss_data_i                (ss_data_i),
    .ss_addr_i                (ss_addr_i),
    .ss_select_i              (ss_select_i),
    .ss_write_i               (ss_write_i),
    .ss_read_i                (ss_read_i),
    .ss_query_i               (ss_query_i),
    .ss_data_o                (spinner_ss_data),
    .ss_ack_o                 (spinner_ss_ack)
);

wire [7:0] sound_p1 = spinner_personality_i ?
                      {p1_i[7:4], 2'b00, p1_i[1:0]} : p1_i;
wire [7:0] sound_p2 = spinner_personality_i ?
                      {p2_i[7:4], 2'b00, p2_i[1:0]} : p2_i;

logic gp_start;
logic gp_rw;
logic [3:0] gp_addr;
logic [15:0] gp_din;
logic [1:0] gp_we;
logic gp_busy;
logic gp_done;
logic [15:0] gp_dout;
logic gp_irq_clear;
logic sound_reset_n;
logic [10:0] sound_shared_addr;
logic [7:0] sound_shared_din;
logic sound_shared_we;
logic [10:0] sound_ram_addr;
logic [7:0] sound_ram_din;
logic sound_ram_we;
logic [7:0] sound_shared_dout;
logic [10:0] palette_addr;
logic [15:0] palette_data;
logic [63:0] main_ss_data;
logic main_ss_ack;

ghox_main u_main (
    .clk                    (clk),
    .rst                    (rst),
    .halt_n                 (run_i),
    .cpu_run_i              (run_i),
    .ss_irq_i               (ss_irq_i),
    .ss_override_i          (ss_override_i),
    .ss_reset_i             (ss_main_reset_i),
    .ss_cpu_run_i           (ss_cpu_run_i),
    .ss_hold_i              (ss_hold_i),
    .ss_restore_enable_i    (ss_restore_enable_i),
    .ss_restore_commit_i    (ss_restore_commit_i),
    .ss_restore_irq4_i      (ss_restore_irq4_i),
    .ss_restore_coin_control_i(ss_restore_coin_control_i),
    .ss_reset_vector_i      (ss_reset_vector_i),
    .rom_cs                 (main_rom_req_o),
    .rom_addr               (main_rom_addr_o),
    .rom_data               (main_rom_data_i),
    .rom_ok                 (main_rom_ok_i),
    .p1_delta_i             (spinner_personality_i ?
                             p1_spinner_delta : 8'sd0),
    .p2_delta_i             (spinner_personality_i ?
                             p2_spinner_delta : 8'sd0),
    .region_i               ({12'd0, region_i}),
    .gp_start_o             (gp_start),
    .gp_rw_o                (gp_rw),
    .gp_addr_o              (gp_addr),
    .gp_din_o               (gp_din),
    .gp_we_o                (gp_we),
    .gp_busy_i              (gp_busy),
    .gp_done_i              (gp_done),
    .gp_dout_i              (gp_dout),
    .gp_irq_clear_i         (gp_irq_clear),
    .irq4_start_i           (irq4_start),
    .sound_clk_i            (clk),
    .sound_shared_addr_i    (sound_ram_addr),
    .sound_shared_din_i     (sound_ram_din),
    .sound_shared_we_i      (sound_ram_we),
    .sound_shared_dout_o    (sound_shared_dout),
    .wram_scan_addr_i       (13'd0),
    .wram_scan_data_o       (),
    .hs_ram_owned_i         (hs_ram_owned_i),
    .hs_ram_addr_i          (hs_ram_addr_i),
    .hs_ram_we_i            (hs_ram_we_i),
    .hs_ram_data_i          (hs_ram_data_i),
    .hs_ram_q_o             (hs_ram_q_o),
    .wram_cpu_we_o          (main_wram_we_o),
    .palette_scan_addr_i    (palette_addr),
    .palette_scan_data_o    (palette_data),
    .ss_data_i              (ss_data_i),
    .ss_addr_i              (ss_addr_i),
    .ss_select_i            (ss_select_i),
    .ss_write_i             (ss_write_i),
    .ss_read_i              (ss_read_i),
    .ss_query_i             (ss_query_i),
    .ss_data_o              (main_ss_data),
    .ss_ack_o               (main_ss_ack),
    .gp_idle_o              (main_gp_idle_o),
    .cpu_cen_o              (main_cpu_cen),
    .cpu_cenb_o             (),
    .cpu_bus_active_o       (main_cpu_bus_active_o),
    .cpu_rw_o               (main_cpu_rw_o),
    .cpu_addr_o             (main_cpu_addr_o),
    .cpu_dout_o             (main_cpu_dout_o),
    .cpu_din_o              (),
    .cpu_ack_o              (main_cpu_ack_o),
    .cpu_iack_o             (main_cpu_iack_o),
    .p1_analog_read_o       (p1_analog_read),
    .p2_analog_read_o       (p2_analog_read),
    .sound_reset_n_o        (sound_reset_n),
    .irq4_o                 (irq4_o),
    .coin_control_o         (main_coin_control_o),
    .last_program_fetch_o   (),
    .bus_count_o            (main_bus_count_o),
    .rom_read_count_o       (),
    .wram_write_count_o     (),
    .shared_write_count_o   (),
    .gp_access_count_o      (main_gp_access_count_o),
    .palette_write_count_o  (main_palette_write_count_o),
    .unmapped_count_o       ()
);

logic [12:0] gp_vram_addr;
logic [15:0] gp_vram_data;
logic [9:0] gp_object_addr;
logic [15:0] gp_object_data;
logic [127:0] gp_scrolls;
logic [7:0] gp_scroll_flip;
logic [63:0] gp_ss_data;
logic gp_ss_ack;

ghox_gp9001 u_gp9001 (
    .clk                 (clk),
    .rst                 (rst),
    .start_i             (gp_start),
    .rw_i                (gp_rw),
    .addr_i              (gp_addr),
    .din_i               (gp_din),
    .we_i                (gp_we),
    .status_bit_i        (gp_status),
    .busy_o              (gp_busy),
    .done_o              (gp_done),
    .dout_o              (gp_dout),
    .irq_clear_o         (gp_irq_clear),
    .scan_addr_i         (gp_vram_addr),
    .scan_dout_o         (gp_vram_data),
    .obj_buf_start_i     (object_buffer_start),
    .obj_scan_addr_i     (gp_object_addr),
    .obj_scan_dout_o     (gp_object_data),
    .obj_buf_busy_o      (),
    .obj_buf_miss_o      (),
    .ptr_o               (),
    .scroll_select_o     (),
    .scrolls_o           (gp_scrolls),
    .scroll_flip_o       (gp_scroll_flip),
    .vram_write_o        (),
    .scroll_write_o      (),
    .ss_hold_i           (ss_hold_i),
    .ss_restore_enable_i (ss_restore_enable_i),
    .ss_data_i           (ss_data_i),
    .ss_addr_i           (ss_addr_i),
    .ss_select_i         (ss_select_i),
    .ss_write_i          (ss_write_i),
    .ss_read_i           (ss_read_i),
    .ss_query_i          (ss_query_i),
    .ss_data_o           (gp_ss_data),
    .ss_ack_o            (gp_ss_ack)
);

logic tile_gfx_req_logical;
logic [21:0] tile_gfx_addr_logical;
logic object_gfx_req_logical;
logic [21:0] object_gfx_addr_logical;
logic tile_gfx_valid;
logic object_gfx_valid;
logic video_line_ready;
logic [10:0] video_color;
logic [1:0] video_engine_busy;
logic [1:0] video_engine_done;
logic [15:0] video_tile_cycles;
logic [15:0] video_object_cycles;
logic [8:0] video_tile_line_y;
logic [8:0] video_object_line_y;
logic [1:0] video_line_epoch;
logic [1:0] video_line_valid;

ghox_gfx_repack u_tile_repack (
    .logical_addr_i  (tile_gfx_addr_logical),
    .physical_addr_o (tile_gfx_addr_o),
    .valid_o         (tile_gfx_valid)
);

ghox_gfx_repack u_object_repack (
    .logical_addr_i  (object_gfx_addr_logical),
    .physical_addr_o (object_gfx_addr_o),
    .valid_o         (object_gfx_valid)
);

assign tile_gfx_req_o = tile_gfx_req_logical && tile_gfx_valid;
assign object_gfx_req_o = object_gfx_req_logical && object_gfx_valid;
assign tile_gfx_invalid_o = tile_gfx_req_logical && !tile_gfx_valid;
assign object_gfx_invalid_o = object_gfx_req_logical && !object_gfx_valid;

ghox_gp9001_video u_video (
    .clk                  (clk),
    .rst                  (rst || ss_video_reset_i),
    .line_start_i         (line_start),
    .line_commit_i        (line_commit),
    .target_y_i           (line_target_y),
    .target_epoch_i       (line_target_epoch),
    .display_x_i          (hcnt[8:0]),
    .display_y_i          (vcnt),
    .display_epoch_i      (video_epoch),
    .scrolls_i            (gp_scrolls),
    .scroll_flip_i        (gp_scroll_flip),
    .vram_addr_o          (gp_vram_addr),
    .vram_data_i          (gp_vram_data),
    .object_addr_o        (gp_object_addr),
    .object_data_i        (gp_object_data),
    .tile_gfx_req_o       (tile_gfx_req_logical),
    .tile_gfx_addr_o      (tile_gfx_addr_logical),
    .tile_gfx_data_i      (tile_gfx_data_i),
    .tile_gfx_ok_i        (tile_gfx_ok_i && tile_gfx_valid),
    .object_gfx_req_o     (object_gfx_req_logical),
    .object_gfx_addr_o    (object_gfx_addr_logical),
    .object_gfx_data_i    (object_gfx_data_i),
    .object_gfx_ok_i      (object_gfx_ok_i && object_gfx_valid),
    .line_ready_o         (video_line_ready),
    .color_o              (video_color),
    .engine_busy_o        (video_engine_busy),
    .engine_done_o        (video_engine_done),
    .deadline_miss_o      (video_deadline_miss_o),
    .tile_cycles_o        (video_tile_cycles),
    .object_cycles_o      (video_object_cycles),
    .tile_line_y_o        (video_tile_line_y),
    .object_line_y_o      (video_object_line_y),
    .line_epoch_o         (video_line_epoch),
    .line_valid_o         (video_line_valid)
);

assign video_idle_o = !(|video_engine_busy);
assign video_line_ready_o = video_line_ready;
assign video_line_start_o = line_start;
assign video_line_commit_o = line_commit;
assign video_line_target_y_o = line_target_y;
assign video_line_target_epoch_o = line_target_epoch;
assign video_epoch_o = video_epoch;
assign video_engine_busy_o = video_engine_busy;
assign video_engine_done_o = video_engine_done;
assign video_tile_cycles_o = video_tile_cycles;
assign video_object_cycles_o = video_object_cycles;
assign video_tile_line_y_o = video_tile_line_y;
assign video_object_line_y_o = video_object_line_y;
assign video_line_epoch_o = video_line_epoch;
assign video_line_valid_o = video_line_valid;

assign palette_addr = video_color;

always_ff @(posedge clk) begin
    if (rst) begin
        red_o <= 8'd0;
        green_o <= 8'd0;
        blue_o <= 8'd0;
        lhbl_o <= 1'b0;
        lvbl_o <= 1'b0;
        hs_o <= 1'b1;
        vs_o <= 1'b1;
    end else if (pxl_cen_o) begin
        lhbl_o <= hcnt < 10'd320;
        lvbl_o <= vcnt < 9'd240;
        hs_o <= !((hcnt >= 10'd340) && (hcnt < 10'd376));
        vs_o <= !((vcnt >= 9'd244) && (vcnt < 9'd248));
        if (hcnt >= 10'd320 || vcnt >= 9'd240 || !video_line_ready) begin
            red_o <= 8'd0;
            green_o <= 8'd0;
            blue_o <= 8'd0;
        end else begin
            red_o <= {palette_data[4:0], palette_data[4:2]};
            green_o <= {palette_data[9:5], palette_data[9:7]};
            blue_o <= {palette_data[14:10], palette_data[14:12]};
        end
    end
end

logic signed [15:0] sound_left;
logic signed [15:0] sound_right;
logic sound_core_idle;
logic sound_restore_run;
logic sound_restore_inject_we;
logic [10:0] sound_restore_inject_addr;
logic [7:0] sound_restore_inject_data;
logic sound_restore_pending;
logic sound_restore_ss_ack;
logic [63:0] sound_restore_ss_data;

wire main_sound_command =
    main_cpu_ack_o && !main_cpu_rw_o &&
    main_cpu_addr_o == 24'h180000;

ghox_sound_restore u_sound_restore (
    .clk                    (clk),
    .rst                    (rst),
    .main_command_pulse_i   (main_sound_command),
    .main_command_i         (main_cpu_dout_o[7:0]),
    .restore_commit_i       (ss_restore_commit_i),
    .sound_shared_write_i   (sound_shared_we),
    .sound_shared_addr_i    (sound_shared_addr),
    .sound_shared_data_i    (sound_shared_din),
    .restore_run_o          (sound_restore_run),
    .restore_done_o         (sound_restore_done_o),
    .restore_failed_o       (sound_restore_failed_o),
    .runtime_pending_o      (sound_restore_pending),
    .inject_we_o            (sound_restore_inject_we),
    .inject_addr_o          (sound_restore_inject_addr),
    .inject_data_o          (sound_restore_inject_data),
    .ss_data_i              (ss_data_i),
    .ss_addr_i              (ss_addr_i),
    .ss_select_i            (ss_select_i),
    .ss_write_i             (ss_write_i),
    .ss_read_i              (ss_read_i),
    .ss_query_i             (ss_query_i),
    .ss_data_o              (sound_restore_ss_data),
    .ss_ack_o               (sound_restore_ss_ack),
    .bank_command_o         (),
    .bgm_command_o          (),
    .bank_valid_o           (),
    .bgm_valid_o            (),
    .replay_state_o         ()
);

assign sound_ram_addr = sound_restore_inject_we ?
                        sound_restore_inject_addr : sound_shared_addr;
assign sound_ram_din = sound_restore_inject_we ?
                       sound_restore_inject_data : sound_shared_din;
assign sound_ram_we = sound_restore_inject_we || sound_shared_we;

ghox_sound u_sound (
    .clk                  (clk),
    .rst                  (rst || ss_sound_reset_i),
    .cpu_reset_n_i        (sound_reset_n),
    .cpu_cen_i            (sound_cpu_cen &&
                           (!ss_hold_i || sound_restore_run)),
    .opm_cen_i            (opm_tick &&
                           (!ss_hold_i || sound_restore_run)),
    .rom_cs_o             (sound_rom_req_o),
    .rom_addr_o           (sound_rom_addr_o),
    .rom_data_i           (sound_rom_data_i),
    .rom_ok_i             (sound_rom_ok_i),
    .shared_addr_o        (sound_shared_addr),
    .shared_din_o         (sound_shared_din),
    .shared_we_o          (sound_shared_we),
    .shared_dout_i        (sound_shared_dout),
    .dsw_a_i              (dsw_a_i),
    .dsw_b_i              (dsw_b_i),
    .p1_i                 (sound_p1),
    .p2_i                 (sound_p2),
    .system_i             (system_i),
    .sample_o             (sample_o),
    .audio_left_o         (sound_left),
    .audio_right_o        (sound_right),
    .state_load_i         (1'b0),
    .cpu_state_i          (212'd0),
    .cpu_state_o          (),
    .periph_state_i       (320'd0),
    .periph_state_o       (),
    .ram_scan_addr_i      (9'd0),
    .ram_scan_data_o      (),
    .ram_scan_we_i        (1'b0),
    .ram_scan_data_i      (8'd0),
    .physical_addr_o      (),
    .logical_addr_o       (),
    .bus_read_o           (),
    .bus_write_o          (),
    .ym_write_pulse_o     (),
    .ym_addr_o            (),
    .ym_data_o            (),
    .shared_write_count_o (sound_shared_write_count_o),
    .ym_write_count_o     (sound_ym_write_count_o),
    .state_idle_o         (sound_core_idle)
);

assign audio_left_o = fm_enable_i ? sound_left : 16'sd0;
assign audio_right_o = fm_enable_i ? sound_right : 16'sd0;

assign sound_idle_o = sound_core_idle && !sound_restore_pending &&
                      !sound_restore_run;

assign ss_ack_o = main_ss_ack || gp_ss_ack || spinner_ss_ack ||
                  sound_restore_ss_ack;
assign ss_data_o = main_ss_ack ? main_ss_data :
                   gp_ss_ack ? gp_ss_data :
                   spinner_ss_ack ? spinner_ss_data :
                   sound_restore_ss_ack ? sound_restore_ss_data : 64'd0;

endmodule
