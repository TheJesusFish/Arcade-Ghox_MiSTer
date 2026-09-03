// GHSS0001 transaction controller and identity owner.
//
// Mutable owner writes are disabled until the root format word and the full
// Ghox payload/personality identity have been consumed and validated. The
// MC68000 architectural image is captured without modifying fx68k: IRQ7
// enters a private ROM overlay, pushes all registers, and records SSP in the
// first two work-RAM words.
module ghox_savestate #(
    parameter integer IRQ_TIMEOUT_CYCLES = 1048576
) (
    input  logic         clk,
    input  logic         rst,
    input  logic         dwnld_busy_i,
    input  logic         do_save_i,
    input  logic         do_restore_i,
    input  logic         stream_busy_i,
    input  logic         root_format_valid_i,
    output logic         write_start_o,
    output logic         read_start_o,
    output logic         active_o,
    output logic [3:0]   state_o,
    output logic         video_hide_o,

    input  logic [7:0]   abi_version_i,
    input  logic [7:0]   set_id_i,
    input  logic [7:0]   control_id_i,
    input  logic [7:0]   region_table_id_i,
    input  logic [31:0]  payload_length_i,
    input  logic [31:0]  payload_crc32_i,
    input  logic [255:0] payload_sha256_i,

    input  logic [8:0]   vcnt_i,
    input  logic         frame_tick_i,
    input  logic         main_bus_active_i,
    input  logic         main_rw_i,
    input  logic [23:0]  main_addr_i,
    input  logic [15:0]  main_dout_i,
    input  logic         main_ack_i,
    input  logic         main_iack_i,
    input  logic         main_gp_idle_i,
    input  logic         sound_idle_i,
    input  logic         sound_restore_done_i,
    input  logic         sound_restore_failed_i,
    input  logic         video_idle_i,
    input  logic         irq4_i,
    input  logic [7:0]   coin_control_i,

    output logic         irq7_o,
    output logic         main_override_o,
    output logic         main_reset_o,
    output logic         main_run_o,
    output logic         owner_hold_o,
    output logic         restore_enable_o,
    output logic         restore_commit_o,
    output logic         restore_irq4_o,
    output logic [7:0]   restore_coin_control_o,
    output logic [63:0]  reset_vector_o,
    output logic         sound_reset_o,
    output logic         video_reset_o,

    input  logic [63:0]  ss_data_i,
    input  logic [31:0]  ss_addr_i,
    input  logic [7:0]   ss_select_i,
    input  logic         ss_write_i,
    input  logic         ss_read_i,
    input  logic         ss_query_i,
    input  logic [63:0]  owner_ss_data_i,
    input  logic         owner_ss_ack_i,
    output logic [63:0]  ss_data_o,
    output logic         ss_ack_o
);

localparam logic [7:0] SSIDX_GLOBAL = 8'd1;
localparam logic [63:0] GHSS_MAGIC = 64'h4748_5353_3030_3031;
localparam logic [63:0] GHSS_POLICY = {
    16'h5450, // TP board family
    16'h0002, // sound policy: cold boot, bank + one durable BGM replay
    16'h0001, // HD647180 observed-subset implementation policy
    16'h0001  // GHSS schema
};

localparam logic [3:0] SS_IDLE                = 4'd0;
localparam logic [3:0] SS_SAVE_WAIT_SAFE      = 4'd1;
localparam logic [3:0] SS_SAVE_WAIT_IRQ       = 4'd2;
localparam logic [3:0] SS_SAVE_WAIT_SSP       = 4'd3;
localparam logic [3:0] SS_SAVE_WAIT_HOLD      = 4'd4;
localparam logic [3:0] SS_SAVE_WAIT_STREAM    = 4'd5;
localparam logic [3:0] SS_SAVE_WAIT_EXIT      = 4'd6;
localparam logic [3:0] SS_SAVE_WAIT_VIDEO     = 4'd7;
localparam logic [3:0] SS_RESTORE_WAIT_SAFE   = 4'd8;
localparam logic [3:0] SS_RESTORE_WAIT_HOLD   = 4'd9;
localparam logic [3:0] SS_RESTORE_WAIT_STREAM = 4'd10;
localparam logic [3:0] SS_RESTORE_HOLD_RESET  = 4'd11;
localparam logic [3:0] SS_RESTORE_WAIT_RESET  = 4'd12;
localparam logic [3:0] SS_RESTORE_WAIT_VIDEO  = 4'd13;
localparam logic [3:0] SS_SAVE_RETRY          = 4'd14;
localparam logic [3:0] SS_RESTORE_WAIT_SOUND  = 4'd15;
localparam logic [19:0] IRQ_TIMEOUT_COUNT =
    20'(IRQ_TIMEOUT_CYCLES - 1);

logic [3:0] state = SS_IDLE;
logic [19:0] irq_wait_count = 20'd0;
logic [2:0] irq_retry_count = 3'd0;
logic [7:0] reset_count = 8'd0;
logic [31:0] saved_ssp = 32'd0;
logic [31:0] restore_ssp = 32'd0;
logic main_drained = 1'b0;
logic restore_identity_valid = 1'b0;
logic restore_metadata_complete = 1'b0;
logic [63:0] identity_word [0:7];
logic global_ack = 1'b0;
logic [63:0] global_data = 64'd0;

wire safe_point = vcnt_i == 9'd240 &&
                  !main_bus_active_i && main_gp_idle_i &&
                  sound_idle_i && video_idle_i;

assign active_o = state != SS_IDLE;
assign state_o = state;
assign video_hide_o = active_o;
assign irq7_o = state == SS_SAVE_WAIT_IRQ;
assign main_override_o =
    state == SS_SAVE_WAIT_SSP ||
    state == SS_SAVE_WAIT_HOLD ||
    state == SS_SAVE_WAIT_EXIT ||
    state == SS_RESTORE_HOLD_RESET ||
    state == SS_RESTORE_WAIT_SOUND ||
    state == SS_RESTORE_WAIT_RESET;
assign main_reset_o = state == SS_RESTORE_HOLD_RESET;
assign main_run_o =
    !(state == SS_SAVE_WAIT_HOLD && main_drained) &&
    state != SS_SAVE_WAIT_STREAM &&
    state != SS_SAVE_WAIT_VIDEO &&
    state != SS_RESTORE_WAIT_HOLD &&
    state != SS_RESTORE_WAIT_STREAM &&
    state != SS_RESTORE_WAIT_SOUND &&
    state != SS_RESTORE_WAIT_VIDEO;
assign owner_hold_o =
    state == SS_SAVE_WAIT_STREAM ||
    state == SS_SAVE_WAIT_EXIT ||
    state == SS_SAVE_WAIT_VIDEO ||
    state == SS_RESTORE_WAIT_STREAM ||
    state == SS_RESTORE_HOLD_RESET ||
    state == SS_RESTORE_WAIT_SOUND ||
    state == SS_RESTORE_WAIT_RESET ||
    state == SS_RESTORE_WAIT_VIDEO;
assign restore_enable_o =
    state == SS_RESTORE_WAIT_STREAM &&
    restore_identity_valid && restore_metadata_complete;
assign sound_reset_o = state == SS_RESTORE_HOLD_RESET;
assign video_reset_o =
    state == SS_SAVE_WAIT_STREAM ||
    state == SS_RESTORE_WAIT_STREAM ||
    state == SS_RESTORE_HOLD_RESET ||
    state == SS_RESTORE_WAIT_SOUND ||
    state == SS_RESTORE_WAIT_RESET;
assign reset_vector_o = {
    restore_ssp[31:16], restore_ssp[15:0], 16'h00ff, 16'h0008
};

wire [63:0] current_identity_0 = GHSS_MAGIC;
wire [63:0] current_identity_1 = GHSS_POLICY;
wire [63:0] current_identity_2 = {
    payload_crc32_i, payload_length_i
};
wire [63:0] current_identity_3 = payload_sha256_i[255:192];
wire [63:0] current_identity_4 = payload_sha256_i[191:128];
wire [63:0] current_identity_5 = payload_sha256_i[127:64];
wire [63:0] current_identity_6 = payload_sha256_i[63:0];
wire [63:0] current_identity_7 = {
    32'd0, abi_version_i, region_table_id_i, control_id_i, set_id_i
};

function automatic [63:0] identity_read(input [2:0] address);
begin
    case (address)
        3'd0: identity_read = current_identity_0;
        3'd1: identity_read = current_identity_1;
        3'd2: identity_read = current_identity_2;
        3'd3: identity_read = current_identity_3;
        3'd4: identity_read = current_identity_4;
        3'd5: identity_read = current_identity_5;
        3'd6: identity_read = current_identity_6;
        default: identity_read = current_identity_7;
    endcase
end
endfunction

wire first_seven_identity_words_match =
    identity_word[0] == current_identity_0 &&
    identity_word[1] == current_identity_1 &&
    identity_word[2] == current_identity_2 &&
    identity_word[3] == current_identity_3 &&
    identity_word[4] == current_identity_4 &&
    identity_word[5] == current_identity_5 &&
    identity_word[6] == current_identity_6;

always_ff @(posedge clk) begin
    global_ack <= 1'b0;

    if (rst || dwnld_busy_i || do_restore_i) begin
        restore_identity_valid <= 1'b0;
        restore_metadata_complete <= 1'b0;
        restore_ssp <= 32'd0;
        restore_irq4_o <= 1'b0;
        restore_coin_control_o <= 8'd0;
        identity_word[0] <= 64'd0;
        identity_word[1] <= 64'd0;
        identity_word[2] <= 64'd0;
        identity_word[3] <= 64'd0;
        identity_word[4] <= 64'd0;
        identity_word[5] <= 64'd0;
        identity_word[6] <= 64'd0;
        identity_word[7] <= 64'd0;
    end else if (ss_select_i == SSIDX_GLOBAL) begin
        if (ss_query_i) begin
            global_data <= {SSIDX_GLOBAL, 22'd0, 2'd3, 32'd9};
            global_ack <= 1'b1;
        end else if (ss_read_i && ss_addr_i < 32'd9) begin
            if (ss_addr_i == 32'd8) begin
                global_data <= {
                    23'd0, coin_control_i, irq4_i, saved_ssp
                };
            end else begin
                global_data <= identity_read(ss_addr_i[2:0]);
            end
            global_ack <= 1'b1;
        end else if (ss_write_i && ss_addr_i < 32'd9) begin
            if (ss_addr_i < 32'd8)
                identity_word[ss_addr_i[2:0]] <= ss_data_i;
            else begin
                restore_ssp <= ss_data_i[31:0];
                restore_irq4_o <= ss_data_i[32];
                restore_coin_control_o <= ss_data_i[40:33];
                restore_metadata_complete <= 1'b1;
            end

            if (ss_addr_i == 32'd7) begin
                restore_identity_valid <=
                    root_format_valid_i &&
                    first_seven_identity_words_match &&
                    ss_data_i == current_identity_7;
            end
            global_ack <= 1'b1;
        end
    end
end

assign ss_ack_o = global_ack || owner_ss_ack_i;
assign ss_data_o = global_ack ? global_data : owner_ss_data_i;

always_ff @(posedge clk) begin
    restore_commit_o <= 1'b0;

    if (rst || dwnld_busy_i) begin
        state <= SS_IDLE;
        write_start_o <= 1'b0;
        read_start_o <= 1'b0;
        irq_wait_count <= 20'd0;
        irq_retry_count <= 3'd0;
        reset_count <= 8'd0;
        saved_ssp <= 32'd0;
        main_drained <= 1'b0;
    end else begin
        case (state)
            SS_IDLE: begin
                write_start_o <= 1'b0;
                read_start_o <= 1'b0;
                irq_wait_count <= 20'd0;
                irq_retry_count <= 3'd0;
                main_drained <= 1'b0;
                if (do_save_i)
                    state <= SS_SAVE_WAIT_SAFE;
                else if (do_restore_i)
                    state <= SS_RESTORE_WAIT_SAFE;
            end

            SS_SAVE_WAIT_SAFE: begin
                if (safe_point) begin
                    irq_wait_count <= 20'd0;
                    state <= SS_SAVE_WAIT_IRQ;
                end
            end

            SS_SAVE_WAIT_IRQ: begin
                if (main_iack_i) begin
                    irq_wait_count <= 20'd0;
                    state <= SS_SAVE_WAIT_SSP;
                end else if (irq_wait_count == IRQ_TIMEOUT_COUNT) begin
                    irq_wait_count <= 20'd0;
                    if (&irq_retry_count)
                        state <= SS_IDLE;
                    else begin
                        irq_retry_count <= irq_retry_count + 3'd1;
                        state <= SS_SAVE_RETRY;
                    end
                end else begin
                    irq_wait_count <= irq_wait_count + 20'd1;
                end
            end

            SS_SAVE_RETRY: begin
                if (vcnt_i != 9'd240)
                    state <= SS_SAVE_WAIT_SAFE;
            end

            SS_SAVE_WAIT_SSP: begin
                if (main_ack_i && !main_rw_i &&
                    main_addr_i == 24'h080000)
                    saved_ssp[31:16] <= main_dout_i;
                if (main_ack_i && !main_rw_i &&
                    main_addr_i == 24'h080002) begin
                    saved_ssp[15:0] <= main_dout_i;
                    state <= SS_SAVE_WAIT_HOLD;
                end
            end

            SS_SAVE_WAIT_HOLD: begin
                // The SSP low-word acknowledgement changes state while the
                // corresponding fx68k write cycle is still asserted. Keep
                // the private overlay and CPU enable active until that cycle
                // drains, then freeze at the first true bus-idle boundary.
                if (!main_drained && !main_bus_active_i &&
                    main_gp_idle_i)
                    main_drained <= 1'b1;
                if ((main_drained ||
                     (!main_bus_active_i && main_gp_idle_i)) &&
                    sound_idle_i && video_idle_i) begin
                    write_start_o <= 1'b1;
                    state <= SS_SAVE_WAIT_STREAM;
                end
            end

            SS_SAVE_WAIT_STREAM: begin
                if (stream_busy_i && write_start_o)
                    write_start_o <= 1'b0;
                else if (!stream_busy_i && !write_start_o)
                    state <= SS_SAVE_WAIT_EXIT;
            end

            SS_SAVE_WAIT_EXIT: begin
                if (main_ack_i && main_rw_i &&
                    main_addr_i[23:8] != 16'hff00)
                    state <= SS_SAVE_WAIT_VIDEO;
            end

            SS_SAVE_WAIT_VIDEO: begin
                if (frame_tick_i)
                    state <= SS_IDLE;
            end

            SS_RESTORE_WAIT_SAFE: begin
                if (safe_point)
                    state <= SS_RESTORE_WAIT_HOLD;
            end

            SS_RESTORE_WAIT_HOLD: begin
                if (!main_bus_active_i && main_gp_idle_i &&
                    sound_idle_i && video_idle_i) begin
                    read_start_o <= 1'b1;
                    state <= SS_RESTORE_WAIT_STREAM;
                end
            end

            SS_RESTORE_WAIT_STREAM: begin
                if (stream_busy_i && read_start_o)
                    read_start_o <= 1'b0;
                else if (!stream_busy_i && !read_start_o) begin
                    if (root_format_valid_i && restore_identity_valid &&
                        restore_metadata_complete) begin
                        restore_commit_o <= 1'b1;
                        reset_count <= 8'd0;
                        state <= SS_RESTORE_HOLD_RESET;
                    end else begin
                        state <= SS_RESTORE_WAIT_VIDEO;
                    end
                end
            end

            SS_RESTORE_HOLD_RESET: begin
                reset_count <= reset_count + 8'd1;
                if (&reset_count)
                    state <= SS_RESTORE_WAIT_SOUND;
            end

            SS_RESTORE_WAIT_SOUND: begin
                if (sound_restore_done_i || sound_restore_failed_i)
                    state <= SS_RESTORE_WAIT_RESET;
            end

            SS_RESTORE_WAIT_RESET: begin
                if (main_ack_i && main_rw_i &&
                    main_addr_i[23:8] != 16'hff00 &&
                    main_addr_i >= 24'h000008)
                    state <= SS_RESTORE_WAIT_VIDEO;
            end

            SS_RESTORE_WAIT_VIDEO: begin
                if (frame_tick_i)
                    state <= SS_IDLE;
            end

            default: state <= SS_IDLE;
        endcase
    end
end

endmodule
