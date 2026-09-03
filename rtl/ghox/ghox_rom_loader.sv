// Exact 0x148000-byte Ghox MRA stream to JTFrame SDRAM programming bridge.
//
// Bank 0 holds the 0x40000-byte main program followed by the 0x8000-byte
// HD647180 ROM. Bank 1 holds the sequential 0x100000-byte GP9001 region.
module ghox_rom_loader #(
    parameter integer AW = 22
) (
    input  logic          clk,
    input  logic          rst,
    input  logic          ioctl_rom_i,
    input  logic [26:0]   ioctl_addr_i,
    input  logic [7:0]    ioctl_data_i,
    input  logic          ioctl_wr_i,

    output logic          dwnld_busy_o,
    output logic [1:0]    prog_ba_o,
    output logic [AW-1:0] prog_addr_o,
    output logic [15:0]   prog_data_o,
    output logic [1:0]    prog_mask_o,
    output logic          prog_rd_o,
    output logic          prog_we_o,
    input  logic          prog_rdy_i,
    input  logic          prog_ack_i,

    output logic          payload_begin_o,
    output logic          payload_complete_o,
    output logic [26:0]   payload_count_o,
    output logic [31:0]   payload_crc32_o,
    output logic          accepted_o,
    output logic          range_error_o,
    output logic          order_error_o,
    output logic          overflow_error_o,
    output logic [26:0]   last_addr_o
);

localparam logic [26:0] MAIN_END  = 27'h0040000;
localparam logic [26:0] SOUND_END = 27'h0048000;
localparam logic [26:0] IMAGE_END = 27'h0148000;

logic ioctl_rom_d = 1'b0;
logic [31:0] crc_state = 32'hffffffff;

wire new_download = ioctl_rom_i && !ioctl_rom_d;
wire end_download = !ioctl_rom_i && ioctl_rom_d;
wire in_range = ioctl_addr_i < IMAGE_END;
wire terminal_sentinel = ioctl_addr_i == IMAGE_END;
wire target_main = ioctl_addr_i < MAIN_END;
wire target_graphics = ioctl_addr_i >= SOUND_END;
wire [26:0] local_byte_addr = target_graphics ?
                              ioctl_addr_i - SOUND_END : ioctl_addr_i;
wire [21:0] local_word_addr = local_byte_addr[22:1];
// The MRA's 16-bit main interleave is emitted in MAME address order, so the
// even byte belongs in DQ[15:8]. The byte-addressed sound cache and the
// GP9001 renderer use the first byte of each pair in DQ[7:0].
wire [1:0] target_mask = target_main ?
                         (ioctl_addr_i[0] ? 2'b10 : 2'b01) :
                         (local_byte_addr[0] ? 2'b01 : 2'b10);
wire can_accept = !prog_we_o || prog_ack_i;

function automatic [31:0] crc32_byte(
    input [31:0] state,
    input [7:0] value
);
    integer bit_index;
    reg [31:0] next_crc;
begin
    next_crc = state ^ value;
    for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
        next_crc = next_crc[0] ?
                   (next_crc >> 1) ^ 32'hedb88320 :
                   (next_crc >> 1);
    crc32_byte = next_crc;
end
endfunction

assign prog_rd_o = 1'b0;
assign dwnld_busy_o = ioctl_rom_i || prog_we_o;

always_ff @(posedge clk) begin
    ioctl_rom_d <= ioctl_rom_i;
    accepted_o <= 1'b0;
    payload_begin_o <= 1'b0;
    payload_complete_o <= 1'b0;

    if (rst) begin
        ioctl_rom_d <= 1'b0;
        prog_ba_o <= 2'd0;
        prog_addr_o <= '0;
        prog_data_o <= 16'd0;
        prog_mask_o <= 2'b11;
        prog_we_o <= 1'b0;
        payload_count_o <= 27'd0;
        payload_crc32_o <= 32'd0;
        crc_state <= 32'hffffffff;
        accepted_o <= 1'b0;
        payload_begin_o <= 1'b0;
        payload_complete_o <= 1'b0;
        range_error_o <= 1'b0;
        order_error_o <= 1'b0;
        overflow_error_o <= 1'b0;
        last_addr_o <= 27'd0;
    end else begin
        if (prog_we_o && prog_ack_i)
            prog_we_o <= 1'b0;

        if (new_download) begin
            payload_begin_o <= 1'b1;
            payload_count_o <= 27'd0;
            payload_crc32_o <= 32'd0;
            crc_state <= 32'hffffffff;
            range_error_o <= 1'b0;
            order_error_o <= 1'b0;
            overflow_error_o <= 1'b0;
            last_addr_o <= 27'd0;
        end

        if (ioctl_wr_i && ioctl_rom_i) begin
            last_addr_o <= ioctl_addr_i;
            if (!in_range) begin
                if (!terminal_sentinel)
                    range_error_o <= 1'b1;
            end else if (ioctl_addr_i !=
                         (new_download ? 27'd0 : payload_count_o)) begin
                order_error_o <= 1'b1;
            end else if (can_accept) begin
                prog_ba_o <= target_graphics ? 2'd1 : 2'd0;
                prog_addr_o <= local_word_addr[AW-1:0];
                prog_data_o <= {ioctl_data_i, ioctl_data_i};
                prog_mask_o <= target_mask;
                prog_we_o <= 1'b1;
                accepted_o <= 1'b1;
                payload_count_o <= (new_download ? 27'd0 :
                                    payload_count_o) + 1'b1;
                crc_state <= crc32_byte(
                    new_download ? 32'hffffffff : crc_state,
                    ioctl_data_i
                );
            end else begin
                overflow_error_o <= 1'b1;
            end
        end

        if (end_download) begin
            payload_crc32_o <= crc_state ^ 32'hffffffff;
            payload_complete_o <=
                payload_count_o == IMAGE_END &&
                !range_error_o && !order_error_o && !overflow_error_o;
        end

        // prog_rdy_i is not an acceptance pulse. The request remains stable
        // through prog_ack_i; JTFrame applies download backpressure upstream.
    end
end

endmodule
