// SPDX-License-Identifier: GPL-3.0-or-later

// Ghox-local high-score persistence. Each MRA supplies the exact MAME 0.288
// hiscore descriptor at index 4 and a profile-bound 264-byte image at index 2.
// The 68000 is stopped only after its in-flight transfer drains; the existing
// save-state work-RAM port then performs an atomic restore or snapshot.
module ghox_highscore (
    input  logic         clk,
    input  logic         reset,
    input  logic         cpu_reset,

    input  logic [7:0]   rom_set_id,
    input  logic         rom_identity_valid,

    input  logic         config_download,
    input  logic         config_wr,
    input  logic [26:0]  config_addr,
    input  logic [7:0]   config_data,

    input  logic         nvram_download,
    input  logic         nvram_upload,
    input  logic         nvram_wr,
    input  logic         nvram_rd,
    input  logic [26:0]  nvram_addr,
    input  logic [7:0]   nvram_data,
    output logic [7:0]   nvram_q,
    output logic         nvram_wait,

    input  logic         ss_active,
    input  logic         ss_restore_commit,
    input  logic [12:0]  normal_ram_addr,
    input  logic [1:0]   normal_ram_we,
    input  logic [15:0]  normal_ram_data,

    output logic         hold_request,
    input  logic         hold_ack,
    output logic         ram_owned,
    output logic [12:0]  ram_addr,
    output logic [1:0]   ram_we,
    output logic [15:0]  ram_data,
    input  logic [15:0]  ram_q,

    output logic         dirty,
    output logic         ready,
    output logic         active,
    output logic         config_valid,
    output logic [1:0]   active_profile
);

localparam logic [8:0] NVRAM_SIZE       = 9'd264;
localparam logic [8:0] SCORE_WINDOW_SIZE = 9'd256;
localparam logic [7:0] SCORE_DATA_SIZE   = 8'd104;
localparam logic [4:0] CONFIG_SIZE       = 5'd16;

localparam logic [3:0] ST_IDLE                 = 4'd0;
localparam logic [3:0] ST_RESTORE_HOLD         = 4'd1;
localparam logic [3:0] ST_RESTORE_BUFFER_READ  = 4'd2;
localparam logic [3:0] ST_RESTORE_RAM_WRITE    = 4'd3;
localparam logic [3:0] ST_CAPTURE_HOLD         = 4'd4;
localparam logic [3:0] ST_CAPTURE_RAM_READ     = 4'd5;
localparam logic [3:0] ST_CAPTURE_BUFFER_WRITE = 4'd6;

function automatic logic [7:0] expected_config_byte(
    input logic [1:0] profile,
    input logic [4:0] address
);
    logic [23:0] main_start;
    begin
        main_start = (profile == 2'd3) ? 24'h0805a4 : 24'h0805a2;
        case (address)
            5'd0:  expected_config_byte = 8'h00;
            5'd1:  expected_config_byte = main_start[23:16];
            5'd2:  expected_config_byte = main_start[15:8];
            5'd3:  expected_config_byte = main_start[7:0];
            5'd4:  expected_config_byte = 8'h00;
            5'd5:  expected_config_byte = 8'h64;
            5'd6:  expected_config_byte = 8'h00;
            5'd7:  expected_config_byte = 8'h8e;
            5'd8:  expected_config_byte = 8'h00;
            5'd9:  expected_config_byte = 8'h08;
            5'd10: expected_config_byte = 8'h00;
            5'd11: expected_config_byte = 8'h06;
            5'd12: expected_config_byte = 8'h00;
            5'd13: expected_config_byte = 8'h04;
            5'd14: expected_config_byte = 8'h00;
            default: expected_config_byte = 8'h00;
        endcase
    end
endfunction

function automatic logic [7:0] expected_trailer_byte(
    input logic [1:0] profile,
    input logic [2:0] address
);
    begin
        case (address)
            3'd0: expected_trailer_byte = 8'h47; // G
            3'd1: expected_trailer_byte = 8'h48; // H
            3'd2: expected_trailer_byte = 8'h48; // H
            3'd3: expected_trailer_byte = 8'h53; // S
            3'd4: expected_trailer_byte = 8'h10 + {6'd0, profile};
            3'd5: expected_trailer_byte = 8'h08;
            3'd6: expected_trailer_byte = 8'h00;
            default: expected_trailer_byte = 8'h68;
        endcase
    end
endfunction

function automatic logic [13:0] score_byte_address(
    input logic [1:0] profile,
    input logic [7:0] offset
);
    logic [13:0] main_start;
    begin
        main_start = (profile == 2'd3) ? 14'h05a4 : 14'h05a2;
        if (offset < 8'd100)
            score_byte_address = main_start + {6'd0, offset};
        else
            score_byte_address = 14'h0006 +
                                 {6'd0, offset - 8'd100};
    end
endfunction

function automatic logic score_byte_selected(
    input logic [1:0] profile,
    input logic [13:0] address
);
    begin
        case (profile)
            2'd1, 2'd2: score_byte_selected =
                ((address >= 14'h05a2) && (address < 14'h0606)) ||
                ((address >= 14'h0006) && (address < 14'h000a));
            2'd3: score_byte_selected =
                ((address >= 14'h05a4) && (address < 14'h0608)) ||
                ((address >= 14'h0006) && (address < 14'h000a));
            default: score_byte_selected = 1'b0;
        endcase
    end
endfunction

function automatic logic [7:0] select_ram_byte(
    input logic [15:0] word_data,
    input logic        byte_lane
);
    begin
        select_ram_byte = byte_lane ? word_data[7:0] : word_data[15:8];
    end
endfunction

logic        config_download_d = 1'b0;
logic [4:0]  config_count = 5'd0;
logic [2:0]  config_match = 3'b000;
logic        config_error = 1'b0;
logic        config_valid_r = 1'b0;
logic [1:0]  config_profile_r = 2'd0;

logic        nvram_download_d = 1'b0;
logic [8:0]  nvram_count = 9'd0;
logic        nvram_error = 1'b0;
logic        nvram_valid = 1'b0;

wire [1:0] identity_profile = rom_set_id[1:0] + 2'd1;
wire identity_supported = rom_identity_valid && (rom_set_id < 8'd3);
wire profile_valid = config_valid_r && identity_supported &&
                     (config_profile_r == identity_profile);

wire load_buffer_wr = nvram_download && nvram_wr &&
                      (nvram_addr < SCORE_WINDOW_SIZE);
wire [7:0] load_buffer_cpu_q;
wire [7:0] snapshot_buffer_hps_q;

logic [3:0] state = ST_IDLE;
logic [7:0] score_offset = 8'd0;
logic [11:0] sentinel_seen = 12'd0;
logic [7:0] rom_set_id_d = 8'd0;
logic       rom_identity_valid_d = 1'b0;
logic       restore_applied = 1'b0;
logic       dirty_r = 1'b0;
logic       snapshot_valid = 1'b0;

logic       nvram_upload_d = 1'b0;
logic       upload_started = 1'b0;
logic       capture_ready = 1'b0;
logic       upload_post_write = 1'b0;
logic [8:0] upload_read_count = 9'd0;
logic       upload_read_error = 1'b0;

wire identity_changed = (rom_set_id != rom_set_id_d) ||
                        (rom_identity_valid != rom_identity_valid_d);
wire config_started = config_download && !config_download_d;
wire nvram_started = nvram_download && !nvram_download_d;

wire [13:0] current_score_byte_address =
    score_byte_address(config_profile_r, score_offset);
wire [13:0] normal_even_byte_address = {normal_ram_addr, 1'b0};
wire [13:0] normal_odd_byte_address = {normal_ram_addr, 1'b1};
wire normal_score_write = profile_valid &&
    ((normal_ram_we[1] && score_byte_selected(
        config_profile_r, normal_even_byte_address)) ||
     (normal_ram_we[0] && score_byte_selected(
        config_profile_r, normal_odd_byte_address)));

wire scores_ready =
    (config_profile_r == 2'd1) ? &sentinel_seen[3:0] :
    (config_profile_r == 2'd2) ? &sentinel_seen[7:4] :
    (config_profile_r == 2'd3) ? &sentinel_seen[11:8] : 1'b0;

wire snapshot_buffer_wr = state == ST_CAPTURE_BUFFER_WRITE;
wire [7:0] capture_byte = select_ram_byte(
    ram_q, current_score_byte_address[0]
);

jtframe_dual_ram #(.DW(8), .AW(8)) u_load_buffer (
    .clk0  (clk),
    .data0 (nvram_data),
    .addr0 (nvram_addr[7:0]),
    .we0   (load_buffer_wr),
    .q0    (),
    .clk1  (clk),
    .data1 (8'd0),
    .addr1 (score_offset),
    .we1   (1'b0),
    .q1    (load_buffer_cpu_q)
);

jtframe_dual_ram #(.DW(8), .AW(8)) u_snapshot_buffer (
    .clk0  (clk),
    .data0 (8'd0),
    .addr0 (nvram_addr[7:0]),
    .we0   (1'b0),
    .q0    (snapshot_buffer_hps_q),
    .clk1  (clk),
    .data1 (capture_byte),
    .addr1 (score_offset),
    .we1   (snapshot_buffer_wr),
    .q1    ()
);

always_ff @(posedge clk) begin
    config_download_d <= config_download;
    nvram_download_d <= nvram_download;

    if (reset) begin
        config_download_d <= 1'b0;
        config_count <= 5'd0;
        config_match <= 3'b000;
        config_error <= 1'b0;
        config_valid_r <= 1'b0;
        config_profile_r <= 2'd0;
        nvram_download_d <= 1'b0;
        nvram_count <= 9'd0;
        nvram_error <= 1'b0;
        nvram_valid <= 1'b0;
    end else begin
        if (config_started) begin
            config_count <= 5'd0;
            config_match <= 3'b111;
            config_error <= 1'b0;
            config_valid_r <= 1'b0;
            config_profile_r <= 2'd0;
            nvram_valid <= 1'b0;
        end

        if (config_download && config_wr) begin
            if ((config_addr == {22'd0, config_count}) &&
                (config_count < CONFIG_SIZE)) begin
                if (config_data != expected_config_byte(2'd1, config_count))
                    config_match[0] <= 1'b0;
                if (config_data != expected_config_byte(2'd2, config_count))
                    config_match[1] <= 1'b0;
                if (config_data != expected_config_byte(2'd3, config_count))
                    config_match[2] <= 1'b0;
                config_count <= config_count + 5'd1;
            end else begin
                config_error <= 1'b1;
            end
        end

        if (!config_download && config_download_d) begin
            config_valid_r <= !config_error &&
                              (config_count == CONFIG_SIZE) &&
                              identity_supported &&
                              config_match[rom_set_id[1:0]];
            if (!config_error && (config_count == CONFIG_SIZE) &&
                identity_supported && config_match[rom_set_id[1:0]])
                config_profile_r <= identity_profile;
            else
                config_profile_r <= 2'd0;
        end

        if (nvram_started) begin
            nvram_count <= 9'd0;
            nvram_error <= 1'b0;
            nvram_valid <= 1'b0;
        end

        if (nvram_download && nvram_wr) begin
            if ((nvram_addr == {18'd0, nvram_count}) &&
                (nvram_count < NVRAM_SIZE)) begin
                nvram_count <= nvram_count + 9'd1;
                if ((nvram_count >= SCORE_DATA_SIZE) &&
                    (nvram_count < SCORE_WINDOW_SIZE) &&
                    (nvram_data != 8'h00))
                    nvram_error <= 1'b1;
                if ((nvram_count >= SCORE_WINDOW_SIZE) &&
                    (nvram_data != expected_trailer_byte(
                        config_profile_r, nvram_count[2:0])))
                    nvram_error <= 1'b1;
            end else begin
                nvram_error <= 1'b1;
            end
        end

        if (!nvram_download && nvram_download_d)
            nvram_valid <= profile_valid && !nvram_error &&
                           (nvram_count == NVRAM_SIZE);

        if (!identity_supported ||
            (config_valid_r && (config_profile_r != identity_profile)))
            nvram_valid <= 1'b0;
    end
end

always_ff @(posedge clk) begin
    nvram_upload_d <= nvram_upload;
    rom_set_id_d <= rom_set_id;
    rom_identity_valid_d <= rom_identity_valid;

    if (reset || cpu_reset) begin
        state <= ST_IDLE;
        score_offset <= 8'd0;
        sentinel_seen <= 12'd0;
        rom_set_id_d <= rom_set_id;
        rom_identity_valid_d <= rom_identity_valid;
        restore_applied <= 1'b0;
        dirty_r <= 1'b0;
        snapshot_valid <= 1'b0;
        nvram_upload_d <= 1'b0;
        upload_started <= 1'b0;
        capture_ready <= 1'b0;
        upload_post_write <= 1'b0;
        upload_read_count <= 9'd0;
        upload_read_error <= 1'b0;
    end else begin
        if (identity_changed) begin
            sentinel_seen <= 12'd0;
            restore_applied <= 1'b0;
            dirty_r <= 1'b0;
            snapshot_valid <= 1'b0;
            upload_started <= 1'b0;
            capture_ready <= 1'b0;
            upload_post_write <= 1'b0;
            upload_read_count <= 9'd0;
            upload_read_error <= 1'b0;
        end

        if (config_started) begin
            restore_applied <= 1'b0;
            snapshot_valid <= 1'b0;
            upload_started <= 1'b0;
            capture_ready <= 1'b0;
            upload_post_write <= 1'b0;
        end

        if (nvram_started) begin
            restore_applied <= 1'b0;
            snapshot_valid <= 1'b0;
        end

        // Readiness values are initialization writes, not stable table data.
        // Observe all profiles so the writes may precede index-4 delivery.
        if (normal_ram_we[1]) begin
            case (normal_even_byte_address)
                14'h05a2: if (normal_ram_data[15:8] == 8'h00) begin
                               sentinel_seen[0] <= 1'b1;
                               sentinel_seen[4] <= 1'b1;
                           end
                14'h05a4: if (normal_ram_data[15:8] == 8'h00)
                               sentinel_seen[8] <= 1'b1;
                14'h0006: if (normal_ram_data[15:8] == 8'h00) begin
                               sentinel_seen[2] <= 1'b1;
                               sentinel_seen[6] <= 1'b1;
                               sentinel_seen[10] <= 1'b1;
                           end
                default: begin end
            endcase
        end
        if (normal_ram_we[0]) begin
            case (normal_odd_byte_address)
                14'h0605: if (normal_ram_data[7:0] == 8'h8e) begin
                               sentinel_seen[1] <= 1'b1;
                               sentinel_seen[5] <= 1'b1;
                           end
                14'h0607: if (normal_ram_data[7:0] == 8'h8e)
                               sentinel_seen[9] <= 1'b1;
                14'h0009: if (normal_ram_data[7:0] == 8'h00) begin
                               sentinel_seen[3] <= 1'b1;
                               sentinel_seen[7] <= 1'b1;
                               sentinel_seen[11] <= 1'b1;
                           end
                default: begin end
            endcase
        end

        if (!identity_changed && !config_started && !nvram_started &&
            scores_ready && (restore_applied || !nvram_valid) &&
            normal_score_write)
            dirty_r <= 1'b1;

        if (upload_started && capture_ready && normal_score_write)
            upload_post_write <= 1'b1;

        if (nvram_upload && !nvram_upload_d) begin
            upload_started <= 1'b1;
            capture_ready <= !profile_valid;
            snapshot_valid <= 1'b0;
            upload_post_write <= 1'b0;
            upload_read_count <= 9'd0;
            upload_read_error <= 1'b0;
        end

        if (nvram_upload && nvram_rd) begin
            if ((nvram_addr == {18'd0, upload_read_count}) &&
                (upload_read_count < NVRAM_SIZE))
                upload_read_count <= upload_read_count + 9'd1;
            else
                upload_read_error <= 1'b1;
        end

        if (!nvram_upload && nvram_upload_d) begin
            if (capture_ready && snapshot_valid && !upload_read_error &&
                !upload_post_write && !normal_score_write &&
                (upload_read_count == NVRAM_SIZE))
                dirty_r <= 1'b0;
            upload_started <= 1'b0;
            capture_ready <= 1'b0;
            upload_post_write <= 1'b0;
            upload_read_count <= 9'd0;
            upload_read_error <= 1'b0;
        end

        if (identity_changed || config_started || nvram_started) begin
            state <= ST_IDLE;
        end else if (ss_restore_commit) begin
            // Work RAM came from the save-state stream. Never let an older
            // disk NVRAM image overwrite the newly restored state afterward.
            state <= ST_IDLE;
            restore_applied <= 1'b1;
            dirty_r <= profile_valid && scores_ready;
            snapshot_valid <= 1'b0;
            capture_ready <= 1'b0;
            upload_started <= 1'b0;
        end else if (ss_active && (state != ST_IDLE)) begin
            state <= ST_IDLE;
            snapshot_valid <= 1'b0;
            capture_ready <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (profile_valid && nvram_valid && scores_ready &&
                        !restore_applied && !ss_active) begin
                        state <= ST_RESTORE_HOLD;
                    end else if (upload_started && profile_valid &&
                                 scores_ready && !ss_active) begin
                        state <= ST_CAPTURE_HOLD;
                    end
                end

                ST_RESTORE_HOLD: begin
                    if (hold_ack) begin
                        score_offset <= 8'd0;
                        state <= ST_RESTORE_BUFFER_READ;
                    end
                end

                ST_RESTORE_BUFFER_READ:
                    state <= ST_RESTORE_RAM_WRITE;

                ST_RESTORE_RAM_WRITE: begin
                    if (score_offset == SCORE_DATA_SIZE - 8'd1) begin
                        restore_applied <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        score_offset <= score_offset + 8'd1;
                        state <= ST_RESTORE_BUFFER_READ;
                    end
                end

                ST_CAPTURE_HOLD: begin
                    if (hold_ack) begin
                        score_offset <= 8'd0;
                        state <= ST_CAPTURE_RAM_READ;
                    end
                end

                ST_CAPTURE_RAM_READ:
                    state <= ST_CAPTURE_BUFFER_WRITE;

                ST_CAPTURE_BUFFER_WRITE: begin
                    if (score_offset == SCORE_DATA_SIZE - 8'd1) begin
                        snapshot_valid <= 1'b1;
                        capture_ready <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        score_offset <= score_offset + 8'd1;
                        state <= ST_CAPTURE_RAM_READ;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
end

assign hold_request = !reset && !cpu_reset && !ss_active &&
                      (state != ST_IDLE);
assign ram_owned = (state == ST_RESTORE_BUFFER_READ) ||
                   (state == ST_RESTORE_RAM_WRITE) ||
                   (state == ST_CAPTURE_RAM_READ) ||
                   (state == ST_CAPTURE_BUFFER_WRITE);

assign ram_addr = current_score_byte_address[13:1];
assign ram_we = (state == ST_RESTORE_RAM_WRITE) ?
                (current_score_byte_address[0] ? 2'b01 : 2'b10) : 2'b00;
assign ram_data = current_score_byte_address[0] ?
                  {8'd0, load_buffer_cpu_q} :
                  {load_buffer_cpu_q, 8'd0};

wire nvram_score_address = nvram_addr < SCORE_DATA_SIZE;
wire nvram_padding_address = (nvram_addr >= SCORE_DATA_SIZE) &&
                             (nvram_addr < SCORE_WINDOW_SIZE);
wire nvram_trailer_address = (nvram_addr >= SCORE_WINDOW_SIZE) &&
                             (nvram_addr < NVRAM_SIZE);

assign nvram_q = !snapshot_valid ? 8'h00 :
                 nvram_score_address ? snapshot_buffer_hps_q :
                 nvram_padding_address ? 8'h00 :
                 nvram_trailer_address ? expected_trailer_byte(
                    config_profile_r, nvram_addr[2:0]) : 8'h00;

assign nvram_wait = nvram_upload && profile_valid && !capture_ready &&
                    !reset && !cpu_reset;
assign dirty = dirty_r && profile_valid;
assign ready = profile_valid && scores_ready;
assign active = (state != ST_IDLE) || upload_started ||
                config_download || nvram_download;
assign config_valid = profile_valid;
assign active_profile = config_profile_r;

endmodule
