// Strict parser for the 64-byte GHXM ABI carried by MRA index 1.
module ghox_personality (
    input  logic         clk,
    input  logic         rst,
    input  logic         payload_begin_i,
    input  logic         payload_complete_i,
    input  logic [26:0]  payload_count_i,
    input  logic [31:0]  payload_crc32_i,
    input  logic         metadata_active_i,
    input  logic         metadata_wr_i,
    input  logic [26:0]  metadata_addr_i,
    input  logic [7:0]   metadata_data_i,

    output logic         valid_o,
    output logic [7:0]   abi_version_o,
    output logic [7:0]   set_id_o,
    output logic [7:0]   control_id_o,
    output logic [7:0]   region_table_id_o,
    output logic [31:0]  payload_length_o,
    output logic [31:0]  payload_crc32_o,
    output logic [255:0] payload_sha256_o,
    output logic         metadata_complete_o,
    output logic         metadata_error_o
);

logic [7:0] metadata [0:63];
logic metadata_active_d = 1'b0;
logic payload_seen = 1'b0;
integer comb_index;
integer seq_index;

wire metadata_begin = metadata_active_i && !metadata_active_d;
wire metadata_end = !metadata_active_i && metadata_active_d;

logic reserved_zero;
logic fields_valid;
always_comb begin
    reserved_zero = 1'b1;
    for (comb_index = 48; comb_index < 64; comb_index = comb_index + 1)
        if (metadata[comb_index] != 8'd0)
            reserved_zero = 1'b0;

    abi_version_o = metadata[4];
    set_id_o = metadata[5];
    control_id_o = metadata[6];
    region_table_id_o = metadata[7];
    payload_length_o = {
        metadata[11], metadata[10], metadata[9], metadata[8]
    };
    payload_crc32_o = {
        metadata[15], metadata[14], metadata[13], metadata[12]
    };
    for (comb_index = 0; comb_index < 32; comb_index = comb_index + 1)
        payload_sha256_o[255 - comb_index * 8 -: 8] =
            metadata[16 + comb_index];

    fields_valid =
        metadata[0] == 8'h47 &&
        metadata[1] == 8'h48 &&
        metadata[2] == 8'h58 &&
        metadata[3] == 8'h4d &&
        abi_version_o == 8'd1 &&
        set_id_o <= 8'd2 &&
        (control_id_o == 8'd1 || control_id_o == 8'd2) &&
        region_table_id_o <= 8'd1 &&
        payload_length_o == 32'h00148000 &&
        reserved_zero &&
        ((set_id_o == 8'd0 && control_id_o == 8'd1 &&
          region_table_id_o == 8'd0) ||
         (set_id_o == 8'd1 && control_id_o == 8'd2 &&
          region_table_id_o == 8'd0) ||
         (set_id_o == 8'd2 && control_id_o == 8'd2 &&
          region_table_id_o == 8'd1));
end

always_ff @(posedge clk) begin
    metadata_active_d <= metadata_active_i;

    if (rst) begin
        valid_o <= 1'b0;
        metadata_complete_o <= 1'b0;
        metadata_error_o <= 1'b0;
        payload_seen <= 1'b0;
        metadata_active_d <= 1'b0;
        for (seq_index = 0; seq_index < 64; seq_index = seq_index + 1)
            metadata[seq_index] <= 8'd0;
    end else begin
        if (payload_begin_i) begin
            valid_o <= 1'b0;
            payload_seen <= 1'b0;
        end
        if (payload_complete_i)
            payload_seen <= 1'b1;

        if (metadata_begin) begin
            valid_o <= 1'b0;
            metadata_complete_o <= 1'b0;
            metadata_error_o <= 1'b0;
            for (seq_index = 0; seq_index < 64; seq_index = seq_index + 1)
                metadata[seq_index] <= 8'd0;
        end

        if (metadata_wr_i && metadata_active_i) begin
            if (metadata_addr_i < 27'd64)
                metadata[metadata_addr_i[5:0]] <= metadata_data_i;
            else
                metadata_error_o <= 1'b1;
        end

        if (metadata_end) begin
            metadata_complete_o <= 1'b1;
            if (!fields_valid)
                metadata_error_o <= 1'b1;
        end

        if (metadata_complete_o && payload_seen) begin
            if (fields_valid &&
                payload_count_i == 27'h0148000 &&
                payload_crc32_i == payload_crc32_o &&
                !metadata_error_o) begin
                valid_o <= 1'b1;
            end else begin
                valid_o <= 1'b0;
                metadata_error_o <= 1'b1;
            end
        end
    end
end

endmodule
