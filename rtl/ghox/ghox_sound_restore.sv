// Ghox sound-intent owner and cold-restore sequencer.
//
// Real-ROM/MAME proof establishes a one-byte command mailbox at shared
// offset zero.  The HD647180 acknowledges every command by writing FF.
// D0-D3 load a sound-data bank.  42-4E start the multi-voice BGM entries
// described by the ROM table at 0EF3; C2-CE stop the matching entry.  FE
// clears the sound engine.  The main CPU's command FIFO cannot reconstruct
// an already-acknowledged BGM, so the last acknowledged bank/BGM intent is
// the only sound state retained by the cold-restart policy.
//
// Restore holds the main CPU while this block:
//   1. answers the sound ROM's destructive boot handshake with AA at cell 1;
//   2. waits for the boot-ready FF at cell 0;
//   3. replays at most one bank load and exactly one durable BGM start;
//   4. waits for an FF acknowledgement after each replayed command.
module ghox_sound_restore #(
    parameter integer TIMEOUT_CYCLES = 67108864
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        main_command_pulse_i,
    input  logic [7:0]  main_command_i,

    input  logic        restore_commit_i,
    input  logic        sound_shared_write_i,
    input  logic [10:0] sound_shared_addr_i,
    input  logic [7:0]  sound_shared_data_i,

    output logic        restore_run_o,
    output logic        restore_done_o,
    output logic        restore_failed_o,
    output logic        runtime_pending_o,
    output logic        inject_we_o,
    output logic [10:0] inject_addr_o,
    output logic [7:0]  inject_data_o,

    input  logic [63:0] ss_data_i,
    input  logic [31:0] ss_addr_i,
    input  logic [7:0]  ss_select_i,
    input  logic        ss_write_i,
    input  logic        ss_read_i,
    input  logic        ss_query_i,
    output logic [63:0] ss_data_o,
    output logic        ss_ack_o,

    output logic [7:0]  bank_command_o,
    output logic [7:0]  bgm_command_o,
    output logic        bank_valid_o,
    output logic        bgm_valid_o,
    output logic [3:0]  replay_state_o
);

localparam logic [7:0] SSIDX_SOUND_INTENT = 8'd10;

localparam logic [3:0] RP_IDLE            = 4'd0;
localparam logic [3:0] RP_WAIT_BOOT_CLEAR = 4'd1;
localparam logic [3:0] RP_INJECT_AA       = 4'd2;
localparam logic [3:0] RP_WAIT_READY      = 4'd3;
localparam logic [3:0] RP_INJECT_BANK     = 4'd4;
localparam logic [3:0] RP_WAIT_BANK_ACK   = 4'd5;
localparam logic [3:0] RP_INJECT_BGM      = 4'd6;
localparam logic [3:0] RP_WAIT_BGM_ACK    = 4'd7;
localparam logic [3:0] RP_DONE            = 4'd8;
localparam logic [3:0] RP_FAILED          = 4'd9;

localparam logic [25:0] TIMEOUT_COUNT = 26'(TIMEOUT_CYCLES - 1);

logic [7:0] bank_command = 8'd0;
logic [7:0] bgm_command = 8'd0;
logic bank_valid = 1'b0;
logic bgm_valid = 1'b0;
logic [7:0] pending_command = 8'd0;
logic pending_command_valid = 1'b0;
logic [3:0] replay_state = RP_IDLE;
logic [25:0] timeout_count = 26'd0;
logic ss_ack = 1'b0;
logic [63:0] ss_data = 64'd0;

wire sound_ack = sound_shared_write_i &&
                 sound_shared_addr_i == 11'd0 &&
                 sound_shared_data_i == 8'hff;
wire sound_boot_clear = sound_shared_write_i &&
                        sound_shared_addr_i == 11'd1 &&
                        sound_shared_data_i == 8'h00;
wire replay_waiting =
    replay_state == RP_WAIT_BOOT_CLEAR ||
    replay_state == RP_WAIT_READY ||
    replay_state == RP_WAIT_BANK_ACK ||
    replay_state == RP_WAIT_BGM_ACK;

assign restore_run_o =
    replay_state != RP_IDLE &&
    replay_state != RP_DONE &&
    replay_state != RP_FAILED;
assign restore_done_o = replay_state == RP_DONE;
assign restore_failed_o = replay_state == RP_FAILED;
assign runtime_pending_o = pending_command_valid;
assign replay_state_o = replay_state;
assign bank_command_o = bank_command;
assign bgm_command_o = bgm_command;
assign bank_valid_o = bank_valid;
assign bgm_valid_o = bgm_valid;
assign ss_ack_o = ss_ack;
assign ss_data_o = ss_data;

always_comb begin
    inject_we_o = 1'b0;
    inject_addr_o = 11'd0;
    inject_data_o = 8'd0;
    case (replay_state)
        RP_INJECT_AA: begin
            inject_we_o = 1'b1;
            inject_addr_o = 11'd1;
            inject_data_o = 8'haa;
        end
        RP_INJECT_BANK: begin
            inject_we_o = 1'b1;
            inject_data_o = bank_command;
        end
        RP_INJECT_BGM: begin
            inject_we_o = 1'b1;
            inject_data_o = bgm_command;
        end
        default: begin
        end
    endcase
end

// Runtime intent tracking is deliberately limited to the protocol classes
// proven by the Ghox ROM and MAME traces.  A sent command becomes durable
// only after the sound CPU's FF acknowledgement.
always_ff @(posedge clk) begin
    if (rst) begin
        bank_command <= 8'd0;
        bgm_command <= 8'd0;
        bank_valid <= 1'b0;
        bgm_valid <= 1'b0;
        pending_command <= 8'd0;
        pending_command_valid <= 1'b0;
    end else begin
        if (main_command_pulse_i) begin
            pending_command <= main_command_i;
            pending_command_valid <= 1'b1;
        end

        if (sound_ack && pending_command_valid && !restore_run_o) begin
            pending_command_valid <= 1'b0;
            if (pending_command >= 8'hd0 &&
                pending_command <= 8'hd3) begin
                bank_command <= pending_command;
                bank_valid <= 1'b1;
            end

            if (pending_command == 8'hfe) begin
                bgm_valid <= 1'b0;
            end else if (pending_command >= 8'h42 &&
                         pending_command <= 8'h4e) begin
                bgm_command <= pending_command;
                bgm_valid <= 1'b1;
            end else if (pending_command >= 8'hc2 &&
                         pending_command <= 8'hce &&
                         bgm_valid &&
                         bgm_command ==
                             {1'b0, pending_command[6:0]}) begin
                bgm_valid <= 1'b0;
            end
        end

        if (ss_select_i == SSIDX_SOUND_INTENT && ss_write_i &&
            ss_addr_i < 32'd8) begin
            case (ss_addr_i[2:0])
                3'd0: bank_command <= ss_data_i[7:0];
                3'd1: bgm_command <= ss_data_i[7:0];
                3'd2: begin
                    bank_valid <= ss_data_i[0];
                    bgm_valid <= ss_data_i[1];
                end
                default: begin
                end
            endcase
        end

        if (restore_commit_i)
            pending_command_valid <= 1'b0;
    end
end

always_ff @(posedge clk) begin
    ss_ack <= 1'b0;
    if (rst) begin
        ss_data <= 64'd0;
    end else if (ss_select_i == SSIDX_SOUND_INTENT) begin
        if (ss_query_i) begin
            ss_data <= {SSIDX_SOUND_INTENT, 22'd0, 2'd0, 32'd8};
            ss_ack <= 1'b1;
        end else if (ss_read_i && ss_addr_i < 32'd8) begin
            case (ss_addr_i[2:0])
                3'd0: ss_data <= {56'd0, bank_command};
                3'd1: ss_data <= {56'd0, bgm_command};
                3'd2: ss_data <= {62'd0, bgm_valid, bank_valid};
                default: ss_data <= 64'd0;
            endcase
            ss_ack <= 1'b1;
        end else if (ss_write_i && ss_addr_i < 32'd8) begin
            ss_ack <= 1'b1;
        end
    end
end

always_ff @(posedge clk) begin
    if (rst) begin
        replay_state <= RP_IDLE;
        timeout_count <= 26'd0;
    end else if (restore_commit_i) begin
        replay_state <= RP_WAIT_BOOT_CLEAR;
        timeout_count <= 26'd0;
    end else begin
        if (replay_waiting) begin
            if (timeout_count == TIMEOUT_COUNT) begin
                replay_state <= RP_FAILED;
                timeout_count <= 26'd0;
            end else begin
                timeout_count <= timeout_count + 26'd1;
            end
        end else begin
            timeout_count <= 26'd0;
        end

        case (replay_state)
            RP_WAIT_BOOT_CLEAR: begin
                if (sound_boot_clear) begin
                    replay_state <= RP_INJECT_AA;
                    timeout_count <= 26'd0;
                end
            end

            RP_INJECT_AA: begin
                replay_state <= RP_WAIT_READY;
            end

            RP_WAIT_READY: begin
                if (sound_ack) begin
                    timeout_count <= 26'd0;
                    if (bank_valid)
                        replay_state <= RP_INJECT_BANK;
                    else if (bgm_valid)
                        replay_state <= RP_INJECT_BGM;
                    else
                        replay_state <= RP_DONE;
                end
            end

            RP_INJECT_BANK: begin
                replay_state <= RP_WAIT_BANK_ACK;
            end

            RP_WAIT_BANK_ACK: begin
                if (sound_ack) begin
                    timeout_count <= 26'd0;
                    if (bgm_valid)
                        replay_state <= RP_INJECT_BGM;
                    else
                        replay_state <= RP_DONE;
                end
            end

            RP_INJECT_BGM: begin
                replay_state <= RP_WAIT_BGM_ACK;
            end

            RP_WAIT_BGM_ACK: begin
                if (sound_ack) begin
                    timeout_count <= 26'd0;
                    replay_state <= RP_DONE;
                end
            end

            default: begin
            end
        endcase
    end
end

endmodule
