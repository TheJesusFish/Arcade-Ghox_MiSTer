// Save-state owner for both Ghox spinner accumulators and fallback arbiters.
module ghox_spinner_state #(
    parameter logic [7:0] SS_IDX = 8'd9
) (
    input  logic         clk,
    input  logic         rst,
    input  logic         restore_enable_i,
    input  logic         restore_commit_i,

    input  logic [7:0]   p1_current_i,
    input  logic [7:0]   p1_consumed_i,
    input  logic         p1_last_toggle_i,
    input  logic         p1_pending_i,
    input  logic         p1_physical_owner_i,
    input  logic [17:0]  p1_fallback_phase_i,
    input  logic [18:0]  p1_physical_holdoff_i,
    input  logic [7:0]   p2_current_i,
    input  logic [7:0]   p2_consumed_i,
    input  logic         p2_last_toggle_i,
    input  logic         p2_pending_i,
    input  logic         p2_physical_owner_i,
    input  logic [17:0]  p2_fallback_phase_i,
    input  logic [18:0]  p2_physical_holdoff_i,

    output logic         state_load_o,
    output logic [7:0]   p1_current_o,
    output logic [7:0]   p1_consumed_o,
    output logic         p1_last_toggle_o,
    output logic         p1_pending_o,
    output logic         p1_physical_owner_o,
    output logic [17:0]  p1_fallback_phase_o,
    output logic [18:0]  p1_physical_holdoff_o,
    output logic [7:0]   p2_current_o,
    output logic [7:0]   p2_consumed_o,
    output logic         p2_last_toggle_o,
    output logic         p2_pending_o,
    output logic         p2_physical_owner_o,
    output logic [17:0]  p2_fallback_phase_o,
    output logic [18:0]  p2_physical_holdoff_o,

    input  logic [63:0]  ss_data_i,
    input  logic [31:0]  ss_addr_i,
    input  logic [7:0]   ss_select_i,
    input  logic         ss_write_i,
    input  logic         ss_read_i,
    input  logic         ss_query_i,
    output logic [63:0]  ss_data_o,
    output logic         ss_ack_o
);

logic [63:0] restore_word [0:1];
wire [63:0] current_word_1 = {
    8'd0, p1_physical_holdoff_i, p1_fallback_phase_i,
    p1_physical_owner_i, p1_pending_i, p1_last_toggle_i,
    p1_consumed_i, p1_current_i
};
wire [63:0] current_word_2 = {
    8'd0, p2_physical_holdoff_i, p2_fallback_phase_i,
    p2_physical_owner_i, p2_pending_i, p2_last_toggle_i,
    p2_consumed_i, p2_current_i
};

always_comb begin
    p1_current_o = restore_word[0][7:0];
    p1_consumed_o = restore_word[0][15:8];
    p1_last_toggle_o = restore_word[0][16];
    p1_pending_o = restore_word[0][17];
    p1_physical_owner_o = restore_word[0][18];
    p1_fallback_phase_o = restore_word[0][36:19];
    p1_physical_holdoff_o = restore_word[0][55:37];
    p2_current_o = restore_word[1][7:0];
    p2_consumed_o = restore_word[1][15:8];
    p2_last_toggle_o = restore_word[1][16];
    p2_pending_o = restore_word[1][17];
    p2_physical_owner_o = restore_word[1][18];
    p2_fallback_phase_o = restore_word[1][36:19];
    p2_physical_holdoff_o = restore_word[1][55:37];
end

always_ff @(posedge clk) begin
    ss_ack_o <= 1'b0;
    state_load_o <= 1'b0;

    if (rst) begin
        restore_word[0] <= 64'd0;
        restore_word[1] <= 64'd0;
    end else begin
        if (restore_commit_i)
            state_load_o <= 1'b1;

        if (ss_select_i == SS_IDX) begin
            if (ss_query_i) begin
                ss_data_o <= {SS_IDX, 22'd0, 2'd3, 32'd2};
                ss_ack_o <= 1'b1;
            end else if (ss_write_i && ss_addr_i < 32'd2) begin
                if (restore_enable_i)
                    restore_word[ss_addr_i[0]] <= ss_data_i;
                ss_ack_o <= 1'b1;
            end else if (ss_read_i && ss_addr_i < 32'd2) begin
                ss_data_o <= ss_addr_i[0] ? current_word_2 : current_word_1;
                ss_ack_o <= 1'b1;
            end
        end
    end
end

endmodule
