// TP-021 HD647180X + YM2151 sound-board boundary.
//
// The CPU is the Ghox-observed, MAME-pinned VHDL subset. External decode is
// physical (20-bit), never PC-banked. YM bus requests are held until an
// IKAOPM 3.375 MHz enable so no CPU write can fall between chip enables.
module ghox_sound #(
    // Simulation-only escape hatch for protocol tests that do not consume
    // audio samples.  Production leaves the exact IKAOPM model enabled.
    parameter integer MODEL_YM_AUDIO = 1
) (
    input  logic         clk,
    input  logic         rst,
    input  logic         cpu_reset_n_i,
    input  logic         cpu_cen_i,
    input  logic         opm_cen_i,

    output logic         rom_cs_o,
    output logic [14:0]  rom_addr_o,
    input  logic [7:0]   rom_data_i,
    input  logic         rom_ok_i,

    output logic [10:0]  shared_addr_o,
    output logic [7:0]   shared_din_o,
    output logic         shared_we_o,
    input  logic [7:0]   shared_dout_i,

    input  logic [7:0]   dsw_a_i,
    input  logic [7:0]   dsw_b_i,
    input  logic [7:0]   p1_i,
    input  logic [7:0]   p2_i,
    input  logic [7:0]   system_i,

    output logic         sample_o,
    output logic signed [15:0] audio_left_o,
    output logic signed [15:0] audio_right_o,

    input  logic         state_load_i,
    input  logic [211:0] cpu_state_i,
    output logic [211:0] cpu_state_o,
    input  logic [319:0] periph_state_i,
    output logic [319:0] periph_state_o,
    input  logic [8:0]   ram_scan_addr_i,
    output logic [7:0]   ram_scan_data_o,
    input  logic         ram_scan_we_i,
    input  logic [7:0]   ram_scan_data_i,

    output logic [19:0]  physical_addr_o,
    output logic [15:0]  logical_addr_o,
    output logic         bus_read_o,
    output logic         bus_write_o,
    output logic         ym_write_pulse_o,
    output logic [7:0]   ym_addr_o,
    output logic [7:0]   ym_data_o,
    output logic [31:0]  shared_write_count_o,
    output logic [31:0]  ym_write_count_o,
    output logic         state_idle_o
);

logic [19:0] physical_addr;
logic [15:0] logical_addr;
logic [7:0] cpu_data_in;
logic [7:0] cpu_data_out;
logic mreq_n;
logic iorq_n;
logic rd_n;
logic wr_n;
logic m1_n;
logic rfsh_n;
logic halt_n;
logic busak_n;
logic [47:0] port_out;
logic [47:0] port_oe;
logic otim;
logic io_write_pulse;
logic [7:0] io_port;
logic [7:0] cbr;
logic [7:0] bbr;
logic [7:0] cbar;
logic wait_n;

logic external_read;
logic external_write;
logic external_access;
logic rom_access;
logic shared_access;
logic ym_access;

assign external_read = !mreq_n && !rd_n;
assign external_write = !mreq_n && !wr_n;
assign external_access = external_read || external_write;
assign rom_access = external_read && physical_addr <= 20'h07fff;
assign shared_access = external_access &&
                       physical_addr >= 20'h40000 &&
                       physical_addr <= 20'h407ff;
assign ym_access = external_access &&
                   (physical_addr == 20'h8000e ||
                    physical_addr == 20'h8000f);

assign rom_cs_o = rom_access;
assign rom_addr_o = physical_addr[14:0];
assign shared_addr_o = physical_addr[10:0];
assign shared_din_o = cpu_data_out;
assign physical_addr_o = physical_addr;
assign logical_addr_o = logical_addr;
assign bus_read_o = external_read;
assign bus_write_o = external_write;

logic ym_pending = 1'b0;
logic ym_complete = 1'b0;
logic ym_rw_latched = 1'b1;
logic ym_a0_latched = 1'b0;
logic [7:0] ym_data_latched = 8'd0;
logic [7:0] opm_dout;
logic transaction_active = 1'b0;
assign state_idle_o = !external_access && !transaction_active &&
                      !ym_pending && !ym_complete;

wire signed [15:0] opm_left_raw;
wire signed [15:0] opm_right_raw;
assign audio_left_o = opm_left_raw;
assign audio_right_o = opm_right_raw;

// ROM and YM are the only external targets that can stretch a CPU cycle.
always_comb begin
    wait_n = 1'b1;
    if (rom_access && !rom_ok_i)
        wait_n = 1'b0;
    else if (ym_access && !ym_complete)
        wait_n = 1'b0;
end

always_comb begin
    cpu_data_in = 8'hff;
    if (rom_access)
        cpu_data_in = rom_data_i;
    else if (shared_access)
        cpu_data_in = shared_dout_i;
    else begin
        case (physical_addr)
            20'h80002: cpu_data_in = dsw_a_i;
            20'h80004: cpu_data_in = dsw_b_i;
            20'h80006: cpu_data_in = 8'h00;
            20'h80008: cpu_data_in = p1_i;
            20'h8000a: cpu_data_in = p2_i;
            20'h8000c, 20'h8000d: cpu_data_in = system_i;
            20'h8000e, 20'h8000f: cpu_data_in = opm_dout;
            default: cpu_data_in = 8'hff;
        endcase
    end
end

always_ff @(posedge clk) begin
    shared_we_o <= 1'b0;
    ym_write_pulse_o <= 1'b0;

    if (rst) begin
        transaction_active <= 1'b0;
        ym_pending <= 1'b0;
        ym_complete <= 1'b0;
        ym_rw_latched <= 1'b1;
        ym_a0_latched <= 1'b0;
        ym_data_latched <= 8'd0;
        ym_addr_o <= 8'd0;
        ym_data_o <= 8'd0;
        shared_write_count_o <= 32'd0;
        ym_write_count_o <= 32'd0;
    end else begin
        if (!external_access) begin
            transaction_active <= 1'b0;
        end else if (!transaction_active) begin
            transaction_active <= 1'b1;
            if (shared_access && external_write) begin
                shared_we_o <= 1'b1;
                shared_write_count_o <= shared_write_count_o + 32'd1;
            end
        end

        if (!ym_access) begin
            ym_pending <= 1'b0;
            ym_complete <= 1'b0;
        end else begin
            if (!ym_pending && !ym_complete) begin
                ym_pending <= 1'b1;
                ym_rw_latched <= external_read;
                ym_a0_latched <= physical_addr[0];
                ym_data_latched <= cpu_data_out;
            end
            if (ym_pending && opm_cen_i) begin
                ym_pending <= 1'b0;
                ym_complete <= 1'b1;
                if (!ym_rw_latched) begin
                    ym_write_pulse_o <= 1'b1;
                    ym_addr_o <= {7'd0, ym_a0_latched};
                    ym_data_o <= ym_data_latched;
                    ym_write_count_o <= ym_write_count_o + 32'd1;
                end
            end
        end
    end
end

generate
    if (MODEL_YM_AUDIO != 0) begin : g_ym_audio
        dogyuun_opm u_ym2151 (
            .rst    (rst),
            .clk    (clk),
            .cen    (opm_cen_i),
            .cs_n   (~ym_pending),
            .wr_n   (~(ym_pending && !ym_rw_latched)),
            .a0     (ym_a0_latched),
            .din    (ym_data_latched),
            .dout   (opm_dout),
            .sample (sample_o),
            .left   (opm_left_raw),
            .right  (opm_right_raw)
        );
    end else begin : g_ym_protocol_stub
        // Ghox does not route a YM IRQ to the sound CPU.  Returning a clear
        // busy bit plus an asserted timer-A status bit is sufficient for the
        // ROM's two observed polls: bit 7 must clear before register writes
        // and bit 0 must set after its timer setup.  The full IKAOPM test
        // separately proves the actual timer transition and audio bus.
        assign opm_dout = 8'h01;
        assign sample_o = 1'b0;
        assign opm_left_raw = 16'sd0;
        assign opm_right_raw = 16'sd0;
    end
endgenerate

ghox_hd647180 u_sound_cpu (
    .clk_i             (clk),
    .cen_i             (cpu_cen_i),
    .reset_n_i         (!rst && cpu_reset_n_i),
    .wait_n_i          (wait_n),
    .int_n_i           (1'b1),
    .nmi_n_i           (1'b1),
    .busrq_n_i         (1'b1),
    .physical_a_o      (physical_addr),
    .logical_a_o       (logical_addr),
    .data_i            (cpu_data_in),
    .data_o            (cpu_data_out),
    .mreq_n_o          (mreq_n),
    .iorq_n_o          (iorq_n),
    .rd_n_o            (rd_n),
    .wr_n_o            (wr_n),
    .m1_n_o            (m1_n),
    .rfsh_n_o          (rfsh_n),
    .halt_n_o          (halt_n),
    .busak_n_o         (busak_n),
    .port_i_i          ({56{1'b1}}),
    .port_o_o          (port_out),
    .port_oe_o         (port_oe),
    .state_load_i      (state_load_i),
    .cpu_state_i       (cpu_state_i),
    .cpu_state_o       (cpu_state_o),
    .periph_state_i    (periph_state_i),
    .periph_state_o    (periph_state_o),
    .ram_scan_a_i      (ram_scan_addr_i),
    .ram_scan_data_o   (ram_scan_data_o),
    .ram_scan_we_i     (ram_scan_we_i),
    .ram_scan_data_i   (ram_scan_data_i),
    .otim_o            (otim),
    .io_write_pulse_o  (io_write_pulse),
    .io_port_o         (io_port),
    .cbr_o             (cbr),
    .bbr_o             (bbr),
    .cbar_o            (cbar)
);

endmodule
