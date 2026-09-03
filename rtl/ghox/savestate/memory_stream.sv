// Ghox canonical GHSS0001 save-state transport.
//
// The eight bytes at start_addr are the private Main_MiSTer slot envelope:
// a 32-bit change detector followed by the stream length in 32-bit words.
// The bytes beginning at start_addr+8 are the exact public GHSS0001 stream:
// fixed header, canonical directory, then contiguous owner chunks.
//
// Restore is deliberately two-pass. The complete header, directory, identity,
// whole-stream CRC, and every chunk CRC are checked while DDR is acquired
// before write_req can assert. Only a fully validated stream is scattered to
// mutable owners.
module memory_stream #(
    parameter integer COUNT = 10
) (
    input               clk,
    input               reset,

    ddr_if.to_host      ddr,

    // Restore writes into state owners.
    output reg          write_req,
    output reg [63:0]   write_data,
    input               data_ack,

    // Save reads from state owners.
    output reg          read_req,
    input      [63:0]   read_data,

    input      [31:0]   start_addr,
    input      [31:0]   length,
    input               read_start,
    input               write_start,

    output reg          query_req,
    output reg [31:0]   chunk_address,
    output reg  [7:0]   chunk_select,

    output              busy,
    output reg          format_valid
);

localparam integer OWNER_COUNT = 10;
localparam integer HEADER_BYTES = 128;
localparam integer DIRECTORY_ENTRY_BYTES = 32;
localparam integer DIRECTORY_BYTES = OWNER_COUNT * DIRECTORY_ENTRY_BYTES;
localparam integer DATA_OFFSET = HEADER_BYTES + DIRECTORY_BYTES;
localparam integer TOTAL_BYTES = 43576;
localparam integer TOTAL_WORDS = TOTAL_BYTES / 8;
localparam integer META_WORDS = DATA_OFFSET / 8;
localparam [31:0] STREAM_BASE_DELTA = 32'd8;
localparam [63:0] HEADER_MAGIC_LE = 64'h3130_3030_5353_4847;
localparam [63:0] HEADER_SCHEMA_WORD = 64'h0000_0000_0080_0001;
localparam [63:0] OWNER_MAGIC = 64'h4748_5353_3030_3031;
localparam [63:0] OWNER_POLICY = 64'h5450_0002_0001_0001;

typedef enum logic [5:0] {
    ST_IDLE,
    ST_ENVELOPE_REQ,
    ST_ENVELOPE_WAIT,
    ST_QUERY_REQ,
    ST_QUERY_WAIT,
    ST_LOAD_ID_REQ,
    ST_LOAD_ID_WAIT,
    ST_SAVE_OWNER_REQ,
    ST_SAVE_OWNER_WAIT,
    ST_SAVE_OWNER_PAD,
    ST_SAVE_OWNER_CRC,
    ST_SAVE_WORD_REQ,
    ST_SAVE_WORD_WAIT,
    ST_SAVE_META_REQ,
    ST_SAVE_META_WAIT,
    ST_SAVE_CRC_REQ,
    ST_SAVE_CRC_WAIT,
    ST_SAVE_CRC_APPLY,
    ST_SAVE_CRC_FINISH,
    ST_SAVE_PATCH_REQ,
    ST_SAVE_PATCH_WAIT,
    ST_SAVE_SIZE_REQ,
    ST_SAVE_SIZE_WAIT,
    ST_SAVE_CHANGE_REQ,
    ST_SAVE_CHANGE_WAIT,
    ST_LOAD_META_REQ,
    ST_LOAD_META_WAIT,
    ST_LOAD_META_APPLY,
    ST_LOAD_CRC_REQ,
    ST_LOAD_CRC_WAIT,
    ST_LOAD_CRC_APPLY,
    ST_LOAD_CRC_CHECK,
    ST_LOAD_DATA_REQ,
    ST_LOAD_DATA_WAIT,
    ST_LOAD_OWNER_REQ,
    ST_LOAD_OWNER_WAIT,
    ST_ABORT
} state_t;

state_t state = ST_IDLE;

reg operation_restore;
reg [3:0] owner_index;
reg [31:0] owner_unit_index;
reg [2:0] unit_slot;
reg [31:0] current_addr;
reg [31:0] word_index;
reg [63:0] buffer;
reg [63:0] crc_data;
reg [3:0] crc_bytes_left;
reg [63:0] envelope_word;
reg [31:0] state_sequence;
reg [3:0] query_delay;
reg pending_owner_end;
reg validation_failed;
reg [31:0] stream_crc;
reg [31:0] owner_crc;
reg [31:0] recorded_stream_crc;
reg [31:0] recorded_owner_crc [0:OWNER_COUNT-1];
reg [31:0] saved_owner_crc [0:OWNER_COUNT-1];
reg [63:0] identity_word [0:7];
integer reset_index;

assign busy = state != ST_IDLE;

function automatic [7:0] owner_select_of(input [3:0] index);
begin
    case (index)
        4'd0: owner_select_of = 8'd1; // GLOB
        4'd1: owner_select_of = 8'd6; // GPST
        4'd2: owner_select_of = 8'd5; // GVRM
        4'd3: owner_select_of = 8'd7; // OBJ0
        4'd4: owner_select_of = 8'd8; // OBJ1
        4'd5: owner_select_of = 8'd4; // PALR
        4'd6: owner_select_of = 8'd3; // SHAR
        4'd7: owner_select_of = 8'd10; // SINT
        4'd8: owner_select_of = 8'd9; // SPIN
        default: owner_select_of = 8'd2; // WRAM
    endcase
end
endfunction

function automatic [31:0] owner_id_le(input [3:0] index);
begin
    case (index)
        4'd0: owner_id_le = 32'h424f4c47; // GLOB
        4'd1: owner_id_le = 32'h54535047; // GPST
        4'd2: owner_id_le = 32'h4d525647; // GVRM
        4'd3: owner_id_le = 32'h304a424f; // OBJ0
        4'd4: owner_id_le = 32'h314a424f; // OBJ1
        4'd5: owner_id_le = 32'h524c4150; // PALR
        4'd6: owner_id_le = 32'h52414853; // SHAR
        4'd7: owner_id_le = 32'h544e4953; // SINT
        4'd8: owner_id_le = 32'h4e495053; // SPIN
        default: owner_id_le = 32'h4d415257; // WRAM
    endcase
end
endfunction

function automatic [1:0] owner_width_of(input [3:0] index);
begin
    case (index)
        4'd0, 4'd8: owner_width_of = 2'd3;
        4'd6, 4'd7: owner_width_of = 2'd0;
        default: owner_width_of = 2'd1;
    endcase
end
endfunction

function automatic [31:0] owner_units_of(input [3:0] index);
begin
    case (index)
        4'd0: owner_units_of = 32'd9;
        4'd1: owner_units_of = 32'd11;
        4'd2: owner_units_of = 32'd8192;
        4'd3, 4'd4: owner_units_of = 32'd1024;
        4'd5, 4'd6: owner_units_of = 32'd2048;
        4'd7: owner_units_of = 32'd8;
        4'd8: owner_units_of = 32'd2;
        default: owner_units_of = 32'd8192;
    endcase
end
endfunction

function automatic [31:0] stored_units_of(input [3:0] index);
begin
    // GPST owns eleven 16-bit values plus one schema-reserved zero value.
    stored_units_of = owner_units_of(index) +
                      ((index == 4'd1) ? 32'd1 : 32'd0);
end
endfunction

function automatic [31:0] owner_length_of(input [3:0] index);
begin
    owner_length_of = stored_units_of(index) << owner_width_of(index);
end
endfunction

function automatic [31:0] owner_offset_of(input [3:0] index);
begin
    case (index)
        4'd0: owner_offset_of = 32'd448;
        4'd1: owner_offset_of = 32'd520;
        4'd2: owner_offset_of = 32'd544;
        4'd3: owner_offset_of = 32'd16928;
        4'd4: owner_offset_of = 32'd18976;
        4'd5: owner_offset_of = 32'd21024;
        4'd6: owner_offset_of = 32'd25120;
        4'd7: owner_offset_of = 32'd27168;
        4'd8: owner_offset_of = 32'd27176;
        default: owner_offset_of = 32'd27192;
    endcase
end
endfunction

function automatic [2:0] unit_end_slot(input [1:0] width);
begin
    case (width)
        2'd0: unit_end_slot = 3'd7;
        2'd1: unit_end_slot = 3'd3;
        2'd2: unit_end_slot = 3'd1;
        default: unit_end_slot = 3'd0;
    endcase
end
endfunction

function automatic [63:0] insert_unit(
    input [63:0] old_buffer,
    input [63:0] unit_data,
    input [1:0] width,
    input [2:0] slot
);
reg [63:0] result;
begin
    result = old_buffer;
    case (width)
        2'd0: case (slot)
            3'd0: result[7:0] = unit_data[7:0];
            3'd1: result[15:8] = unit_data[7:0];
            3'd2: result[23:16] = unit_data[7:0];
            3'd3: result[31:24] = unit_data[7:0];
            3'd4: result[39:32] = unit_data[7:0];
            3'd5: result[47:40] = unit_data[7:0];
            3'd6: result[55:48] = unit_data[7:0];
            default: result[63:56] = unit_data[7:0];
        endcase
        2'd1: case (slot)
            3'd0: result[15:0] = unit_data[15:0];
            3'd1: result[31:16] = unit_data[15:0];
            3'd2: result[47:32] = unit_data[15:0];
            default: result[63:48] = unit_data[15:0];
        endcase
        2'd2: begin
            if (slot == 0)
                result[31:0] = unit_data[31:0];
            else
                result[63:32] = unit_data[31:0];
        end
        default: result = unit_data;
    endcase
    insert_unit = result;
end
endfunction

function automatic [63:0] extract_unit(
    input [63:0] source,
    input [1:0] width,
    input [2:0] slot
);
begin
    extract_unit = 64'd0;
    case (width)
        2'd0: case (slot)
            3'd0: extract_unit[7:0] = source[7:0];
            3'd1: extract_unit[7:0] = source[15:8];
            3'd2: extract_unit[7:0] = source[23:16];
            3'd3: extract_unit[7:0] = source[31:24];
            3'd4: extract_unit[7:0] = source[39:32];
            3'd5: extract_unit[7:0] = source[47:40];
            3'd6: extract_unit[7:0] = source[55:48];
            default: extract_unit[7:0] = source[63:56];
        endcase
        2'd1: case (slot)
            3'd0: extract_unit[15:0] = source[15:0];
            3'd1: extract_unit[15:0] = source[31:16];
            3'd2: extract_unit[15:0] = source[47:32];
            default: extract_unit[15:0] = source[63:48];
        endcase
        2'd2: begin
            if (slot == 0)
                extract_unit[31:0] = source[31:0];
            else
                extract_unit[31:0] = source[63:32];
        end
        default: extract_unit = source;
    endcase
end
endfunction

function automatic [63:0] reverse_bytes64(input [63:0] value);
begin
    reverse_bytes64 = {
        value[7:0], value[15:8], value[23:16], value[31:24],
        value[39:32], value[47:40], value[55:48], value[63:56]
    };
end
endfunction

function automatic [31:0] crc32_byte(
    input [31:0] crc_in,
    input [7:0] byte_in
);
reg [31:0] value;
integer bit_index;
begin
    value = crc_in ^ byte_in;
    for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
        value = value[0] ? ((value >> 1) ^ 32'hedb88320) :
                           (value >> 1);
    crc32_byte = value;
end
endfunction

function automatic [63:0] header_word(input [4:0] index);
begin
    case (index)
        5'd0: header_word = HEADER_MAGIC_LE;
        5'd1: header_word = HEADER_SCHEMA_WORD;
        5'd2: header_word = {32'd128, 32'(TOTAL_BYTES)};
        5'd3: header_word = {
            identity_word[7][31:0], 16'd32, 16'(OWNER_COUNT)
        };
        5'd4: header_word = identity_word[2];
        5'd5: header_word = reverse_bytes64(identity_word[3]);
        5'd6: header_word = reverse_bytes64(identity_word[4]);
        5'd7: header_word = reverse_bytes64(identity_word[5]);
        5'd8: header_word = reverse_bytes64(identity_word[6]);
        5'd9: header_word = {
            state_sequence,
            identity_word[1][47:32],
            identity_word[1][31:16]
        };
        default: header_word = 64'd0;
    endcase
end
endfunction

function automatic [63:0] directory_word(
    input [3:0] owner,
    input [1:0] subword
);
begin
    case (subword)
        2'd0: directory_word = {
            16'd0, 16'd1, owner_id_le(owner)
        };
        2'd1: directory_word = {
            owner_length_of(owner), owner_offset_of(owner)
        };
        2'd2: directory_word = {
            saved_owner_crc[owner], owner_length_of(owner)
        };
        default: directory_word = 64'd0;
    endcase
end
endfunction

wire [1:0] active_width = owner_width_of(owner_index);
wire [31:0] active_units = owner_units_of(owner_index);
wire [31:0] active_stored_units = stored_units_of(owner_index);
wire [63:0] packed_read_data =
    insert_unit(buffer, read_data, active_width, unit_slot);
wire [63:0] packed_zero =
    insert_unit(buffer, 64'd0, active_width, unit_slot);
wire active_word_full = unit_slot == unit_end_slot(active_width);
wire active_last_stored_unit =
    owner_unit_index + 32'd1 == active_stored_units;
wire active_last_physical_unit =
    owner_unit_index + 32'd1 == active_units;
wire [31:0] active_last_word =
    (owner_offset_of(owner_index) + owner_length_of(owner_index)) / 8 - 1;

reg [63:0] save_meta_data;
reg [3:0] meta_owner;
reg [1:0] meta_subword;
always_comb begin
    meta_owner = 4'd0;
    meta_subword = 2'd0;
    if (word_index < 32'd16) begin
        save_meta_data = header_word(word_index[4:0]);
    end else begin
        meta_owner = word_index[5:2] - 4'd4;
        meta_subword = word_index[1:0];
        save_meta_data = directory_word(meta_owner, meta_subword);
    end
end

reg load_meta_word_valid;
reg [3:0] load_meta_owner;
reg [1:0] load_meta_subword;
always_comb begin
    load_meta_word_valid = 1'b1;
    load_meta_owner = 4'd0;
    load_meta_subword = 2'd0;

    if (word_index < 32'd16) begin
        case (word_index[4:0])
            5'd0: load_meta_word_valid =
                buffer == HEADER_MAGIC_LE;
            5'd1: load_meta_word_valid =
                buffer == HEADER_SCHEMA_WORD;
            5'd2: load_meta_word_valid =
                buffer == {32'd128, 32'(TOTAL_BYTES)};
            5'd3: load_meta_word_valid =
                buffer == {
                    identity_word[7][31:0], 16'd32, 16'(OWNER_COUNT)
                };
            5'd4: load_meta_word_valid =
                buffer == identity_word[2];
            5'd5: load_meta_word_valid =
                buffer == reverse_bytes64(identity_word[3]);
            5'd6: load_meta_word_valid =
                buffer == reverse_bytes64(identity_word[4]);
            5'd7: load_meta_word_valid =
                buffer == reverse_bytes64(identity_word[5]);
            5'd8: load_meta_word_valid =
                buffer == reverse_bytes64(identity_word[6]);
            5'd9: load_meta_word_valid =
                buffer[31:0] == {
                    identity_word[1][47:32],
                    identity_word[1][31:16]
                };
            5'd10: load_meta_word_valid = buffer[63:32] == 32'd0;
            default: load_meta_word_valid = buffer == 64'd0;
        endcase
    end else begin
        load_meta_owner = word_index[5:2] - 4'd4;
        load_meta_subword = word_index[1:0];
        case (load_meta_subword)
            2'd0: load_meta_word_valid =
                buffer == {
                    16'd0, 16'd1, owner_id_le(load_meta_owner)
                };
            2'd1: load_meta_word_valid =
                buffer == {
                    owner_length_of(load_meta_owner),
                    owner_offset_of(load_meta_owner)
                };
            2'd2: load_meta_word_valid =
                buffer[31:0] == owner_length_of(load_meta_owner);
            default: load_meta_word_valid = buffer == 64'd0;
        endcase
    end
end

always_comb begin
    chunk_select = owner_select_of(owner_index);
end

always_ff @(posedge clk) begin
    if (reset) begin
        state <= ST_IDLE;
        operation_restore <= 1'b0;
        ddr.acquire <= 1'b0;
        ddr.addr <= 32'd0;
        ddr.wdata <= 64'd0;
        ddr.read <= 1'b0;
        ddr.write <= 1'b0;
        ddr.burstcnt <= 8'd1;
        ddr.byteenable <= 8'hff;
        write_req <= 1'b0;
        write_data <= 64'd0;
        read_req <= 1'b0;
        query_req <= 1'b0;
        chunk_address <= 32'd0;
        format_valid <= 1'b0;
        owner_index <= 4'd0;
        owner_unit_index <= 32'd0;
        unit_slot <= 3'd0;
        current_addr <= 32'd0;
        word_index <= 32'd0;
        buffer <= 64'd0;
        crc_data <= 64'd0;
        crc_bytes_left <= 4'd0;
        envelope_word <= 64'd0;
        state_sequence <= 32'd0;
        query_delay <= 4'd0;
        pending_owner_end <= 1'b0;
        validation_failed <= 1'b0;
        stream_crc <= 32'hffff_ffff;
        owner_crc <= 32'hffff_ffff;
        recorded_stream_crc <= 32'd0;
        for (reset_index = 0; reset_index < OWNER_COUNT;
             reset_index = reset_index + 1) begin
            recorded_owner_crc[reset_index] <= 32'd0;
            saved_owner_crc[reset_index] <= 32'd0;
        end
        for (reset_index = 0; reset_index < 8;
             reset_index = reset_index + 1)
            identity_word[reset_index] <= 64'd0;
    end else begin
        case (state)
            ST_IDLE: begin
                ddr.acquire <= 1'b0;
                ddr.read <= 1'b0;
                ddr.write <= 1'b0;
                ddr.byteenable <= 8'hff;
                write_req <= 1'b0;
                read_req <= 1'b0;
                query_req <= 1'b0;
                if (read_start || write_start) begin
                    operation_restore <= read_start;
                    format_valid <= 1'b0;
                    validation_failed <= 1'b0;
                    ddr.acquire <= 1'b1;
                    state <= ST_ENVELOPE_REQ;
                end
            end

            ST_ENVELOPE_REQ: begin
                if (!ddr.busy) begin
                    ddr.addr <= start_addr;
                    ddr.read <= 1'b1;
                    state <= ST_ENVELOPE_WAIT;
                end
            end

            ST_ENVELOPE_WAIT: begin
                if (!ddr.busy && ddr.rdata_ready) begin
                    ddr.read <= 1'b0;
                    envelope_word <= ddr.rdata;
                    state_sequence <= ddr.rdata[31:0] + 32'd1;
                    if (operation_restore &&
                        ddr.rdata[63:32] != 32'(TOTAL_BYTES / 4)) begin
                        state <= ST_ABORT;
                    end else begin
                        owner_index <= 4'd0;
                        query_delay <= 4'd0;
                        state <= ST_QUERY_REQ;
                    end
                end
            end

            ST_QUERY_REQ: begin
                if (!data_ack) begin
                    query_req <= 1'b1;
                    read_req <= 1'b1;
                    query_delay <= 4'd0;
                    state <= ST_QUERY_WAIT;
                end
            end

            ST_QUERY_WAIT: begin
                if (data_ack) begin
                    query_req <= 1'b0;
                    read_req <= 1'b0;
                    if (read_data != {
                        owner_select_of(owner_index),
                        22'd0,
                        owner_width_of(owner_index),
                        owner_units_of(owner_index)
                    }) begin
                        state <= ST_ABORT;
                    end else if (owner_index == OWNER_COUNT - 1) begin
                        owner_index <= 4'd0;
                        owner_unit_index <= 32'd0;
                        chunk_address <= 32'd0;
                        if (operation_restore)
                            state <= ST_LOAD_ID_REQ;
                        else begin
                            current_addr <= start_addr +
                                            STREAM_BASE_DELTA +
                                            32'(DATA_OFFSET);
                            unit_slot <= 3'd0;
                            buffer <= 64'd0;
                            owner_crc <= 32'hffff_ffff;
                            state <= ST_SAVE_OWNER_REQ;
                        end
                    end else begin
                        owner_index <= owner_index + 4'd1;
                        state <= ST_QUERY_REQ;
                    end
                end else if (&query_delay) begin
                    query_req <= 1'b0;
                    read_req <= 1'b0;
                    state <= ST_ABORT;
                end else begin
                    query_delay <= query_delay + 4'd1;
                end
            end

            // Capture the live identity without mutating any owner. It is the
            // expected identity for the header validation pass.
            ST_LOAD_ID_REQ: begin
                if (!data_ack) begin
                    chunk_address <= owner_unit_index;
                    read_req <= 1'b1;
                    state <= ST_LOAD_ID_WAIT;
                end
            end

            ST_LOAD_ID_WAIT: begin
                if (data_ack) begin
                    read_req <= 1'b0;
                    identity_word[owner_unit_index[2:0]] <= read_data;
                    if (owner_unit_index == 32'd7) begin
                        if (identity_word[0] != OWNER_MAGIC ||
                            identity_word[1] != OWNER_POLICY) begin
                            state <= ST_ABORT;
                        end else begin
                            word_index <= 32'd0;
                            validation_failed <= 1'b0;
                            current_addr <= start_addr + STREAM_BASE_DELTA;
                            state <= ST_LOAD_META_REQ;
                        end
                    end else begin
                        owner_unit_index <= owner_unit_index + 32'd1;
                        state <= ST_LOAD_ID_REQ;
                    end
                end
            end

            ST_SAVE_OWNER_REQ: begin
                if (owner_unit_index == active_units) begin
                    state <= ST_SAVE_OWNER_PAD;
                end else if (!data_ack) begin
                    chunk_address <= owner_unit_index;
                    read_req <= 1'b1;
                    state <= ST_SAVE_OWNER_WAIT;
                end
            end

            ST_SAVE_OWNER_WAIT: begin
                if (data_ack) begin
                    read_req <= 1'b0;
                    buffer <= packed_read_data;
                    crc_data <= read_data;
                    crc_bytes_left <= 4'd1 << active_width;
                    if (owner_index == 0 && owner_unit_index < 32'd8)
                        identity_word[owner_unit_index[2:0]] <= read_data;
                    state <= ST_SAVE_OWNER_CRC;
                end
            end

            ST_SAVE_OWNER_PAD: begin
                // Only GPST reaches this state: its twelfth 16-bit value is
                // schema-reserved zero, making every chunk 64-bit aligned.
                buffer <= packed_zero;
                crc_data <= 64'd0;
                crc_bytes_left <= 4'd1 << active_width;
                state <= ST_SAVE_OWNER_CRC;
            end

            // The state transport is not throughput-sensitive. Updating one
            // byte per master clock removes the eight-byte combinational CRC
            // matrix from the 94.5 MHz owner path.
            ST_SAVE_OWNER_CRC: begin
                owner_crc <= crc32_byte(owner_crc, crc_data[7:0]);
                crc_data <= {8'd0, crc_data[63:8]};
                if (crc_bytes_left == 4'd1) begin
                    owner_unit_index <= owner_unit_index + 32'd1;
                    if (active_word_full) begin
                        pending_owner_end <= active_last_stored_unit;
                        state <= ST_SAVE_WORD_REQ;
                    end else begin
                        unit_slot <= unit_slot + 3'd1;
                        state <= ST_SAVE_OWNER_REQ;
                    end
                end else begin
                    crc_bytes_left <= crc_bytes_left - 4'd1;
                end
            end

            ST_SAVE_WORD_REQ: begin
                if (!ddr.busy) begin
                    ddr.addr <= current_addr;
                    ddr.wdata <= buffer;
                    ddr.write <= 1'b1;
                    state <= ST_SAVE_WORD_WAIT;
                end
            end

            ST_SAVE_WORD_WAIT: begin
                if (!ddr.busy) begin
                    ddr.write <= 1'b0;
                    current_addr <= current_addr + 32'd8;
                    buffer <= 64'd0;
                    unit_slot <= 3'd0;
                    if (pending_owner_end) begin
                        saved_owner_crc[owner_index] <=
                            owner_crc ^ 32'hffff_ffff;
                        pending_owner_end <= 1'b0;
                        if (owner_index == OWNER_COUNT - 1) begin
                            word_index <= 32'd0;
                            current_addr <= start_addr +
                                            STREAM_BASE_DELTA;
                            state <= ST_SAVE_META_REQ;
                        end else begin
                            owner_index <= owner_index + 4'd1;
                            owner_unit_index <= 32'd0;
                            owner_crc <= 32'hffff_ffff;
                            state <= ST_SAVE_OWNER_REQ;
                        end
                    end else begin
                        state <= ST_SAVE_OWNER_REQ;
                    end
                end
            end

            ST_SAVE_META_REQ: begin
                if (!ddr.busy) begin
                    ddr.addr <= current_addr;
                    ddr.wdata <= save_meta_data;
                    ddr.write <= 1'b1;
                    state <= ST_SAVE_META_WAIT;
                end
            end

            ST_SAVE_META_WAIT: begin
                if (!ddr.busy) begin
                    ddr.write <= 1'b0;
                    if (word_index == META_WORDS - 1) begin
                        word_index <= 32'd0;
                        current_addr <= start_addr +
                                        STREAM_BASE_DELTA;
                        stream_crc <= 32'hffff_ffff;
                        state <= ST_SAVE_CRC_REQ;
                    end else begin
                        word_index <= word_index + 32'd1;
                        current_addr <= current_addr + 32'd8;
                        state <= ST_SAVE_META_REQ;
                    end
                end
            end

            ST_SAVE_CRC_REQ: begin
                if (!ddr.busy) begin
                    ddr.addr <= current_addr;
                    ddr.read <= 1'b1;
                    state <= ST_SAVE_CRC_WAIT;
                end
            end

            ST_SAVE_CRC_WAIT: begin
                if (!ddr.busy && ddr.rdata_ready) begin
                    ddr.read <= 1'b0;
                    // The whole-stream CRC treats its own low 32-bit field as
                    // zero. Consume the latched word one byte per clock.
                    buffer <= (word_index == 32'd10) ?
                              {ddr.rdata[63:32], 32'd0} : ddr.rdata;
                    crc_data <= (word_index == 32'd10) ?
                                {ddr.rdata[63:32], 32'd0} : ddr.rdata;
                    crc_bytes_left <= 4'd8;
                    state <= ST_SAVE_CRC_APPLY;
                end
            end

            ST_SAVE_CRC_APPLY: begin
                stream_crc <= crc32_byte(stream_crc, crc_data[7:0]);
                crc_data <= {8'd0, crc_data[63:8]};
                if (crc_bytes_left == 4'd1) begin
                    if (word_index == TOTAL_WORDS - 1) begin
                        state <= ST_SAVE_CRC_FINISH;
                    end else begin
                        word_index <= word_index + 32'd1;
                        current_addr <= current_addr + 32'd8;
                        state <= ST_SAVE_CRC_REQ;
                    end
                end else begin
                    crc_bytes_left <= crc_bytes_left - 4'd1;
                end
            end

            ST_SAVE_CRC_FINISH: begin
                recorded_stream_crc <= stream_crc ^ 32'hffff_ffff;
                state <= ST_SAVE_PATCH_REQ;
            end

            ST_SAVE_PATCH_REQ: begin
                if (!ddr.busy) begin
                    ddr.addr <= start_addr + STREAM_BASE_DELTA + 32'd80;
                    ddr.wdata <= {32'd0, recorded_stream_crc};
                    ddr.write <= 1'b1;
                    state <= ST_SAVE_PATCH_WAIT;
                end
            end

            ST_SAVE_PATCH_WAIT: begin
                if (!ddr.busy) begin
                    ddr.write <= 1'b0;
                    state <= ST_SAVE_SIZE_REQ;
                end
            end

            // Commit the MiSTer envelope size before its change detector.
            ST_SAVE_SIZE_REQ: begin
                if (!ddr.busy) begin
                    ddr.addr <= start_addr;
                    ddr.wdata <= {
                        32'(TOTAL_BYTES / 4), envelope_word[31:0]
                    };
                    ddr.byteenable <= 8'hf0;
                    ddr.write <= 1'b1;
                    state <= ST_SAVE_SIZE_WAIT;
                end
            end

            ST_SAVE_SIZE_WAIT: begin
                if (!ddr.busy) begin
                    ddr.write <= 1'b0;
                    ddr.byteenable <= 8'hff;
                    state <= ST_SAVE_CHANGE_REQ;
                end
            end

            ST_SAVE_CHANGE_REQ: begin
                if (!ddr.busy) begin
                    ddr.addr <= start_addr;
                    ddr.wdata <= {
                        envelope_word[63:32],
                        envelope_word[31:0] + 32'd1
                    };
                    ddr.byteenable <= 8'h0f;
                    ddr.write <= 1'b1;
                    state <= ST_SAVE_CHANGE_WAIT;
                end
            end

            ST_SAVE_CHANGE_WAIT: begin
                if (!ddr.busy) begin
                    ddr.write <= 1'b0;
                    ddr.byteenable <= 8'hff;
                    ddr.acquire <= 1'b0;
                    state <= ST_IDLE;
                end
            end

            ST_LOAD_META_REQ: begin
                if (!ddr.busy) begin
                    ddr.addr <= current_addr;
                    ddr.read <= 1'b1;
                    state <= ST_LOAD_META_WAIT;
                end
            end

            ST_LOAD_META_WAIT: begin
                if (!ddr.busy && ddr.rdata_ready) begin
                    ddr.read <= 1'b0;
                    // Break the HPS DDR read-data path before the wide
                    // identity/directory comparators. The transport is not
                    // throughput-sensitive and the extra cycle is internal.
                    buffer <= ddr.rdata;
                    state <= ST_LOAD_META_APPLY;
                end
            end

            ST_LOAD_META_APPLY: begin
                    if (!load_meta_word_valid)
                        validation_failed <= 1'b1;
                    if (word_index == 32'd9)
                        state_sequence <= buffer[63:32];
                    if (word_index == 32'd10)
                        recorded_stream_crc <= buffer[31:0];
                    if (word_index >= 32'd16 &&
                        load_meta_subword == 2'd2)
                        recorded_owner_crc[load_meta_owner] <=
                            buffer[63:32];

                    if (word_index == META_WORDS - 1) begin
                        if (validation_failed || !load_meta_word_valid) begin
                            state <= ST_ABORT;
                        end else begin
                            word_index <= 32'd0;
                            current_addr <= start_addr +
                                            STREAM_BASE_DELTA;
                            owner_index <= 4'd0;
                            stream_crc <= 32'hffff_ffff;
                            owner_crc <= 32'hffff_ffff;
                            validation_failed <= 1'b0;
                            state <= ST_LOAD_CRC_REQ;
                        end
                    end else begin
                        word_index <= word_index + 32'd1;
                        current_addr <= current_addr + 32'd8;
                        state <= ST_LOAD_META_REQ;
                    end
            end

            ST_LOAD_CRC_REQ: begin
                if (!ddr.busy) begin
                    ddr.addr <= current_addr;
                    ddr.read <= 1'b1;
                    state <= ST_LOAD_CRC_WAIT;
                end
            end

            ST_LOAD_CRC_WAIT: begin
                if (!ddr.busy && ddr.rdata_ready) begin
                    ddr.read <= 1'b0;
                    buffer <= (word_index == 32'd10) ?
                              {ddr.rdata[63:32], 32'd0} : ddr.rdata;
                    crc_data <= (word_index == 32'd10) ?
                                {ddr.rdata[63:32], 32'd0} : ddr.rdata;
                    crc_bytes_left <= 4'd8;
                    state <= ST_LOAD_CRC_APPLY;
                end
            end

            ST_LOAD_CRC_APPLY: begin
                stream_crc <= crc32_byte(stream_crc, crc_data[7:0]);
                if (word_index >= DATA_OFFSET / 8)
                    owner_crc <= crc32_byte(owner_crc, crc_data[7:0]);
                crc_data <= {8'd0, crc_data[63:8]};
                if (crc_bytes_left == 4'd1)
                    state <= ST_LOAD_CRC_CHECK;
                else
                    crc_bytes_left <= crc_bytes_left - 4'd1;
            end

            ST_LOAD_CRC_CHECK: begin
                if (word_index >= DATA_OFFSET / 8 &&
                    owner_index == 4'd1 &&
                    word_index == active_last_word &&
                    buffer[63:48] != 16'd0)
                    validation_failed <= 1'b1;

                if (word_index >= DATA_OFFSET / 8 &&
                    word_index == active_last_word) begin
                    if ((owner_crc ^ 32'hffff_ffff) !=
                        recorded_owner_crc[owner_index])
                        validation_failed <= 1'b1;
                    owner_crc <= 32'hffff_ffff;
                    if (owner_index != OWNER_COUNT - 1)
                        owner_index <= owner_index + 4'd1;
                end

                if (word_index == TOTAL_WORDS - 1) begin
                    if (validation_failed ||
                        (owner_index == 4'd1 &&
                         buffer[63:48] != 16'd0) ||
                        ((owner_crc ^ 32'hffff_ffff) !=
                         recorded_owner_crc[owner_index]) ||
                        ((stream_crc ^ 32'hffff_ffff) !=
                         recorded_stream_crc)) begin
                        state <= ST_ABORT;
                    end else begin
                        format_valid <= 1'b1;
                        owner_index <= 4'd0;
                        owner_unit_index <= 32'd0;
                        unit_slot <= 3'd0;
                        current_addr <= start_addr +
                                        STREAM_BASE_DELTA +
                                        owner_offset_of(4'd0);
                        state <= ST_LOAD_DATA_REQ;
                    end
                end else begin
                    word_index <= word_index + 32'd1;
                    current_addr <= current_addr + 32'd8;
                    state <= ST_LOAD_CRC_REQ;
                end
            end

            ST_LOAD_DATA_REQ: begin
                if (!ddr.busy) begin
                    ddr.addr <= current_addr;
                    ddr.read <= 1'b1;
                    state <= ST_LOAD_DATA_WAIT;
                end
            end

            ST_LOAD_DATA_WAIT: begin
                if (!ddr.busy && ddr.rdata_ready) begin
                    ddr.read <= 1'b0;
                    buffer <= ddr.rdata;
                    state <= ST_LOAD_OWNER_REQ;
                end
            end

            ST_LOAD_OWNER_REQ: begin
                if (owner_unit_index == active_units) begin
                    if (owner_index == OWNER_COUNT - 1) begin
                        ddr.acquire <= 1'b0;
                        state <= ST_IDLE;
                    end else begin
                        owner_index <= owner_index + 4'd1;
                        owner_unit_index <= 32'd0;
                        unit_slot <= 3'd0;
                        current_addr <= start_addr +
                                        STREAM_BASE_DELTA +
                                        owner_offset_of(owner_index + 4'd1);
                        state <= ST_LOAD_DATA_REQ;
                    end
                end else if (!data_ack) begin
                    chunk_address <= owner_unit_index;
                    write_data <= extract_unit(
                        buffer, active_width, unit_slot
                    );
                    write_req <= 1'b1;
                    state <= ST_LOAD_OWNER_WAIT;
                end
            end

            ST_LOAD_OWNER_WAIT: begin
                if (data_ack) begin
                    write_req <= 1'b0;
                    owner_unit_index <= owner_unit_index + 32'd1;
                    if (active_last_physical_unit) begin
                        state <= ST_LOAD_OWNER_REQ;
                    end else if (active_word_full) begin
                        unit_slot <= 3'd0;
                        current_addr <= current_addr + 32'd8;
                        state <= ST_LOAD_DATA_REQ;
                    end else begin
                        unit_slot <= unit_slot + 3'd1;
                        state <= ST_LOAD_OWNER_REQ;
                    end
                end
            end

            ST_ABORT: begin
                ddr.read <= 1'b0;
                ddr.write <= 1'b0;
                ddr.byteenable <= 8'hff;
                ddr.acquire <= 1'b0;
                write_req <= 1'b0;
                read_req <= 1'b0;
                query_req <= 1'b0;
                format_valid <= 1'b0;
                state <= ST_IDLE;
            end

            default: state <= ST_ABORT;
        endcase
    end
end

endmodule
