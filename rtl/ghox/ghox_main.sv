// TP-021 MC68000 subsystem: exact 10 MHz enable, board map, local memories,
// one GP9001 transaction port, shared sound RAM, finite DTACK, and IRQ4.
module ghox_main #(
    parameter integer CPU_FIXED_WAIT = 0,
    parameter integer CPU_NUM = 20,
    parameter integer CPU_DEN = 189
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        halt_n,
    input  logic        cpu_run_i,
    input  logic        ss_irq_i,
    input  logic        ss_override_i,
    input  logic        ss_reset_i,
    input  logic        ss_cpu_run_i,
    input  logic        ss_hold_i,
    input  logic        ss_restore_enable_i,
    input  logic        ss_restore_commit_i,
    input  logic        ss_restore_irq4_i,
    input  logic [7:0]  ss_restore_coin_control_i,
    input  logic [63:0] ss_reset_vector_i,

    output logic        rom_cs,
    output logic [16:0] rom_addr,
    input  logic [15:0] rom_data,
    input  logic        rom_ok,

    input  logic signed [7:0] p1_delta_i,
    input  logic signed [7:0] p2_delta_i,
    input  logic [15:0] region_i,

    output logic        gp_start_o,
    output logic        gp_rw_o,
    output logic [3:0]  gp_addr_o,
    output logic [15:0] gp_din_o,
    output logic [1:0]  gp_we_o,
    input  logic        gp_busy_i,
    input  logic        gp_done_i,
    input  logic [15:0] gp_dout_i,
    input  logic        gp_irq_clear_i,
    input  logic        irq4_start_i,

    input  logic        sound_clk_i,
    input  logic [10:0] sound_shared_addr_i,
    input  logic [7:0]  sound_shared_din_i,
    input  logic        sound_shared_we_i,
    output logic [7:0]  sound_shared_dout_o,

    input  logic [12:0] wram_scan_addr_i,
    output logic [15:0] wram_scan_data_o,
    input  logic        hs_ram_owned_i,
    input  logic [12:0] hs_ram_addr_i,
    input  logic [1:0]  hs_ram_we_i,
    input  logic [15:0] hs_ram_data_i,
    output logic [15:0] hs_ram_q_o,
    output logic [1:0]  wram_cpu_we_o,
    input  logic [10:0] palette_scan_addr_i,
    output logic [15:0] palette_scan_data_o,

    input  logic [63:0] ss_data_i,
    input  logic [31:0] ss_addr_i,
    input  logic [7:0]  ss_select_i,
    input  logic        ss_write_i,
    input  logic        ss_read_i,
    input  logic        ss_query_i,
    output logic [63:0] ss_data_o,
    output logic        ss_ack_o,
    output logic        gp_idle_o,

    output logic        cpu_cen_o,
    output logic        cpu_cenb_o,
    output logic        cpu_bus_active_o,
    output logic        cpu_rw_o,
    output logic [23:0] cpu_addr_o,
    output logic [15:0] cpu_dout_o,
    output logic [15:0] cpu_din_o,
    output logic        cpu_ack_o,
    output logic        cpu_iack_o,
    output logic        p1_analog_read_o,
    output logic        p2_analog_read_o,
    output logic        sound_reset_n_o,
    output logic        irq4_o,
    output logic [7:0]  coin_control_o,
    output logic [23:0] last_program_fetch_o,
    output logic [31:0] bus_count_o,
    output logic [31:0] rom_read_count_o,
    output logic [31:0] wram_write_count_o,
    output logic [31:0] shared_write_count_o,
    output logic [31:0] gp_access_count_o,
    output logic [31:0] palette_write_count_o,
    output logic [31:0] unmapped_count_o
);

logic [23:1] cpu_addr;
logic [23:0] cpu_addr8;
logic [15:0] cpu_dout;
logic [15:0] cpu_din = 16'hffff;
logic cpu_as_n;
logic cpu_lds_n;
logic cpu_uds_n;
logic cpu_dtack_n;
logic cpu_fc0;
logic cpu_fc1;
logic cpu_fc2;
logic cpu_rw;
logic cpu_cen;
logic cpu_cenb;
logic cpu_reset_n;
assign sound_reset_n_o = cpu_reset_n;

assign cpu_addr8 = {cpu_addr, 1'b0};
assign cpu_bus_active_o = !cpu_as_n && (!cpu_uds_n || !cpu_lds_n);
assign cpu_rw_o = cpu_rw;
assign cpu_addr_o = cpu_addr8;
assign cpu_dout_o = cpu_dout;
assign cpu_din_o = cpu_din;
assign cpu_cen_o = cpu_cen;
assign cpu_cenb_o = cpu_cenb;
logic cpu_read;
logic cpu_write;
assign cpu_read = cpu_bus_active_o && cpu_rw;
assign cpu_write = cpu_bus_active_o && !cpu_rw;
logic cpu_iack;
assign cpu_iack = !cpu_as_n && cpu_fc0 && cpu_fc1 && cpu_fc2;
assign cpu_iack_o = cpu_iack;
logic cpu_vpa_n;
assign cpu_vpa_n = ~&{cpu_fc0, cpu_fc1, cpu_fc2, ~cpu_as_n};
logic cpu_program_space;
assign cpu_program_space = cpu_fc1 && !cpu_fc0;
logic ss_handler_cs;
logic ss_reset_vector_cs;
logic ss_irq_vector_cs;
logic ss_special_cs;
logic cpu_core_reset;
assign ss_handler_cs = ss_override_i && cpu_bus_active_o &&
                       (cpu_addr8[23:8] == 16'hff00);
assign ss_reset_vector_cs = ss_override_i && cpu_bus_active_o &&
                            (cpu_addr8 < 24'h000008);
assign ss_irq_vector_cs = ss_override_i && cpu_bus_active_o &&
                          ((cpu_addr8 == 24'h00007c) ||
                           (cpu_addr8 == 24'h00007e));
assign ss_special_cs = ss_handler_cs ||
                       ss_reset_vector_cs ||
                       ss_irq_vector_cs;
assign cpu_core_reset = rst || ss_reset_i;

function automatic [15:0] ss_irq_handler_word(input [3:0] index);
begin
    case (index)
        4'h0: ss_irq_handler_word = 16'h48e7; // movem.l d0-a6,-(sp)
        4'h1: ss_irq_handler_word = 16'hfffe;
        4'h2: ss_irq_handler_word = 16'h4e6e; // move usp,a6
        4'h3: ss_irq_handler_word = 16'h2f0e; // move.l a6,-(sp)
        4'h4: ss_irq_handler_word = 16'h4df9; // lea $00080000,a6
        4'h5: ss_irq_handler_word = 16'h0008;
        4'h6: ss_irq_handler_word = 16'h0000;
        4'h7: ss_irq_handler_word = 16'h2c8f; // move.l sp,(a6)
        4'h8: ss_irq_handler_word = 16'h2c5f; // movea.l (sp)+,a6
        4'h9: ss_irq_handler_word = 16'h4e66; // move a6,usp
        4'ha: ss_irq_handler_word = 16'h4cdf; // movem.l (sp)+,d0-a6
        4'hb: ss_irq_handler_word = 16'h7fff;
        4'hc: ss_irq_handler_word = 16'h4e73; // rte
        default: ss_irq_handler_word = 16'h0000;
    endcase
end
endfunction

function automatic [15:0] ss_reset_vector_word(input [1:0] index);
begin
    case (index)
        2'd0: ss_reset_vector_word = ss_reset_vector_i[63:48];
        2'd1: ss_reset_vector_word = ss_reset_vector_i[47:32];
        2'd2: ss_reset_vector_word = ss_reset_vector_i[31:16];
        default: ss_reset_vector_word = ss_reset_vector_i[15:0];
    endcase
end
endfunction

logic rom_bus_cs;
logic rom_read_cs;
logic p2_analog_cs;
logic wram_cs;
logic palette_cs;
logic p1_analog_cs;
logic gp_cs;
logic shared_cs;
logic coin_cs;
logic region_cs;
logic mapped_cs;
logic unmapped_cs;

ghox_main_decode u_decode (
    .addr          (cpu_addr8),
    .bus_active    (cpu_bus_active_o),
    .rw            (cpu_rw),
    .rom_cs        (rom_bus_cs),
    .rom_read_cs   (rom_read_cs),
    .p2_analog_cs  (p2_analog_cs),
    .wram_cs       (wram_cs),
    .palette_cs    (palette_cs),
    .p1_analog_cs  (p1_analog_cs),
    .gp_cs         (gp_cs),
    .shared_cs     (shared_cs),
    .coin_cs       (coin_cs),
    .region_cs     (region_cs),
    .mapped_cs     (mapped_cs),
    .unmapped_cs   (unmapped_cs)
);

logic normal_rom_read_cs;
assign normal_rom_read_cs = rom_read_cs && !ss_special_cs;
assign rom_cs = normal_rom_read_cs;
assign rom_addr = cpu_addr8[17:1];

logic gp_bus_started = 1'b0;
logic gp_bus_done = 1'b0;
assign gp_start_o = gp_cs && !ss_hold_i &&
                    !gp_bus_started && !gp_bus_done;
assign gp_rw_o = cpu_rw;
assign gp_addr_o = cpu_addr8[3:0];
assign gp_din_o = cpu_dout;
assign gp_we_o = {!cpu_uds_n, !cpu_lds_n};
logic gp_wait;
assign gp_wait = gp_cs && !gp_bus_done;
assign gp_idle_o = !gp_bus_started && !gp_busy_i &&
                   !gp_start_o && !gp_wait;

always_ff @(posedge clk) begin
    if (rst || !cpu_bus_active_o || !gp_cs) begin
        gp_bus_started <= 1'b0;
        gp_bus_done <= 1'b0;
    end else begin
        if (gp_start_o)
            gp_bus_started <= 1'b1;
        if (gp_done_i)
            gp_bus_done <= 1'b1;
    end
end

logic cpu_bus_busy;
assign cpu_bus_busy = (normal_rom_read_cs && !rom_ok) || gp_wait;
logic [15:0] cpu_fave;
logic [15:0] cpu_fworst;

jtframe_68kdtack_cen #(
    .W(8),
    .MFREQ(94500),
    .WAIT1(CPU_FIXED_WAIT)
) u_cpu_dtack (
    .rst       (cpu_core_reset),
    .clk       (clk),
    .cpu_cen   (cpu_cen),
    .cpu_cenb  (cpu_cenb),
    .bus_cs    (cpu_bus_active_o),
    .bus_busy  (cpu_bus_busy),
    .bus_legit (1'b0),
    .bus_ack   (1'b0),
    .ASn       (cpu_as_n),
    .DSn       ({cpu_uds_n, cpu_lds_n}),
    .num       (CPU_NUM[6:0]),
    .den       (CPU_DEN[7:0]),
    .wait2     (1'b0),
    .wait3     (1'b0),
    .DTACKn    (cpu_dtack_n),
    .fave      (cpu_fave),
    .fworst    (cpu_fworst)
);

fx68k u_main68k (
    .clk      (clk),
    .HALTn    (halt_n),
    .extReset (cpu_core_reset),
    .pwrUp    (cpu_core_reset),
    .enPhi1   (cpu_cen && cpu_run_i && ss_cpu_run_i),
    .enPhi2   (cpu_cenb && cpu_run_i && ss_cpu_run_i),
    .eRWn     (cpu_rw),
    .ASn      (cpu_as_n),
    .LDSn     (cpu_lds_n),
    .UDSn     (cpu_uds_n),
    .E        (),
    .VMAn     (),
    .FC0      (cpu_fc0),
    .FC1      (cpu_fc1),
    .FC2      (cpu_fc2),
    .BGn      (),
    .oRESETn  (cpu_reset_n),
    .oHALTEDn (),
    .DTACKn   (cpu_dtack_n),
    .VPAn     (cpu_vpa_n),
    .BERRn    (1'b1),
    .BRn      (1'b1),
    .BGACKn   (1'b1),
    .IPL0n    (~ss_irq_i),
    .IPL1n    (~ss_irq_i),
    .IPL2n    (~(ss_irq_i || irq4_o)),
    .iEdb     (cpu_din),
    .oEdb     (cpu_dout),
    .eab      (cpu_addr)
);

logic ack_seen = 1'b0;
logic ack_now;
assign ack_now = cpu_bus_active_o && !cpu_dtack_n && !ack_seen;
assign cpu_ack_o = ack_now;
assign p1_analog_read_o = ack_now && p1_analog_cs && cpu_read;
assign p2_analog_read_o = ack_now && p2_analog_cs && cpu_read;

always_ff @(posedge clk) begin
    if (cpu_core_reset || !cpu_bus_active_o)
        ack_seen <= 1'b0;
    else if (ack_now)
        ack_seen <= 1'b1;
end

logic [1:0] wram_we;
assign wram_cpu_we_o = wram_we;
assign wram_we = {
    ack_now && wram_cs && cpu_write && !cpu_uds_n,
    ack_now && wram_cs && cpu_write && !cpu_lds_n
};
logic shared_we;
assign shared_we = ack_now && shared_cs && cpu_write && !cpu_lds_n;
logic [1:0] palette_we;
assign palette_we = {
    ack_now && palette_cs && cpu_write && !cpu_uds_n,
    ack_now && palette_cs && cpu_write && !cpu_lds_n
};

logic [15:0] wram_dout;
logic [7:0] shared_dout;
logic [15:0] palette_dout;
logic [63:0] ss_wram_data_out;
logic [63:0] ss_shared_data_out;
logic [63:0] ss_palette_data_out;
logic ss_wram_ack;
logic ss_shared_ack;
logic ss_palette_ack;
logic [12:0] ss_wram_addr;
logic [15:0] ss_wram_data;
logic [1:0] ss_wram_we;

dogyuun_ss_ram_port #(
    .WIDTH        (16),
    .ADDR_WIDTH   (13),
    .WE_WIDTH     (2),
    .SS_IDX       (8'd2),
    .STREAM_WIDTH (2'd1)
) u_wram_ss (
    .clk            (clk),
    .restore_enable (ss_restore_enable_i),
    .normal_we      (hs_ram_owned_i ? hs_ram_we_i : 2'b00),
    .normal_addr    (hs_ram_owned_i ? hs_ram_addr_i : wram_scan_addr_i),
    .normal_data    (hs_ram_data_i),
    .ram_we         (ss_wram_we),
    .ram_addr       (ss_wram_addr),
    .ram_data       (ss_wram_data),
    .ram_q          (wram_scan_data_o),
    .ss_data        (ss_data_i),
    .ss_addr        (ss_addr_i),
    .ss_select      (ss_select_i),
    .ss_write       (ss_write_i),
    .ss_read        (ss_read_i),
    .ss_query       (ss_query_i),
    .ss_data_out    (ss_wram_data_out),
    .ss_ack         (ss_wram_ack)
);

assign hs_ram_q_o = wram_scan_data_o;

jtframe_dual_ram16 #(.AW(13)) u_wram (
    .clk0  (clk),
    .data0 (cpu_dout),
    .addr0 (cpu_addr8[13:1]),
    .we0   (wram_we),
    .q0    (wram_dout),
    .clk1  (clk),
    .data1 (ss_wram_data),
    .addr1 (ss_wram_addr),
    .we1   (ss_wram_we),
    .q1    (wram_scan_data_o)
);

logic [10:0] ss_shared_addr;
logic [7:0] ss_shared_data;
logic [0:0] ss_shared_we;

dogyuun_ss_ram_port #(
    .WIDTH        (8),
    .ADDR_WIDTH   (11),
    .WE_WIDTH     (1),
    .SS_IDX       (8'd3),
    .STREAM_WIDTH (2'd0)
) u_shared_ss (
    .clk            (clk),
    .restore_enable (ss_restore_enable_i),
    .normal_we      (sound_shared_we_i),
    .normal_addr    (sound_shared_addr_i),
    .normal_data    (sound_shared_din_i),
    .ram_we         (ss_shared_we),
    .ram_addr       (ss_shared_addr),
    .ram_data       (ss_shared_data),
    .ram_q          (sound_shared_dout_o),
    .ss_data        (ss_data_i),
    .ss_addr        (ss_addr_i),
    .ss_select      (ss_select_i),
    .ss_write       (ss_write_i),
    .ss_read        (ss_read_i),
    .ss_query       (ss_query_i),
    .ss_data_out    (ss_shared_data_out),
    .ss_ack         (ss_shared_ack)
);

jtframe_dual_ram #(.DW(8), .AW(11)) u_shared_ram (
    .clk0  (clk),
    .data0 (cpu_dout[7:0]),
    .addr0 (cpu_addr8[11:1]),
    .we0   (shared_we),
    .q0    (shared_dout),
    .clk1  (sound_clk_i),
    .data1 (ss_shared_data),
    .addr1 (ss_shared_addr),
    .we1   (ss_shared_we[0]),
    .q1    (sound_shared_dout_o)
);

logic [10:0] ss_palette_addr;
logic [15:0] ss_palette_data;
logic [1:0] ss_palette_we;

dogyuun_ss_ram_port #(
    .WIDTH        (16),
    .ADDR_WIDTH   (11),
    .WE_WIDTH     (2),
    .SS_IDX       (8'd4),
    .STREAM_WIDTH (2'd1)
) u_palette_ss (
    .clk            (clk),
    .restore_enable (ss_restore_enable_i),
    .normal_we      (2'b00),
    .normal_addr    (palette_scan_addr_i),
    .normal_data    (16'd0),
    .ram_we         (ss_palette_we),
    .ram_addr       (ss_palette_addr),
    .ram_data       (ss_palette_data),
    .ram_q          (palette_scan_data_o),
    .ss_data        (ss_data_i),
    .ss_addr        (ss_addr_i),
    .ss_select      (ss_select_i),
    .ss_write       (ss_write_i),
    .ss_read        (ss_read_i),
    .ss_query       (ss_query_i),
    .ss_data_out    (ss_palette_data_out),
    .ss_ack         (ss_palette_ack)
);

jtframe_dual_ram16 #(.AW(11)) u_palette_ram (
    .clk0  (clk),
    .data0 (cpu_dout),
    .addr0 (cpu_addr8[11:1]),
    .we0   (palette_we),
    .q0    (palette_dout),
    .clk1  (clk),
    .data1 (ss_palette_data),
    .addr1 (ss_palette_addr),
    .we1   (ss_palette_we),
    .q1    (palette_scan_data_o)
);

assign ss_ack_o = ss_wram_ack || ss_shared_ack || ss_palette_ack;
assign ss_data_o = ss_wram_ack ? ss_wram_data_out :
                   ss_shared_ack ? ss_shared_data_out :
                   ss_palette_ack ? ss_palette_data_out : 64'd0;

logic [15:0] cpu_din_mux;
always_comb begin
    cpu_din_mux = 16'hffff;
    if (ss_handler_cs)
        cpu_din_mux = ss_irq_handler_word(cpu_addr8[4:1]);
    else if (ss_reset_vector_cs)
        cpu_din_mux = ss_reset_vector_word(cpu_addr8[2:1]);
    else if (ss_irq_vector_cs)
        cpu_din_mux = cpu_addr8[1] ? 16'h0000 : 16'h00ff;
    else if (normal_rom_read_cs)
        cpu_din_mux = rom_data;
    else if (wram_cs)
        cpu_din_mux = wram_dout;
    else if (shared_cs)
        cpu_din_mux = {8'hff, shared_dout};
    else if (gp_cs)
        cpu_din_mux = gp_dout_i;
    else if (palette_cs)
        cpu_din_mux = palette_dout;
    else if (p1_analog_cs)
        cpu_din_mux = {{8{p1_delta_i[7]}}, p1_delta_i};
    else if (p2_analog_cs)
        cpu_din_mux = {{8{p2_delta_i[7]}}, p2_delta_i};
    else if (region_cs)
        cpu_din_mux = region_i;
end

always_ff @(posedge clk) begin
    if (cpu_core_reset)
        cpu_din <= 16'hffff;
    else if (cpu_read)
        cpu_din <= cpu_din_mux;
end

logic irq4_latch = 1'b0;
assign irq4_o = irq4_latch;
always_ff @(posedge clk) begin
    if (rst)
        irq4_latch <= 1'b0;
    else if (ss_restore_commit_i)
        irq4_latch <= ss_restore_irq4_i;
    else begin
        if (irq4_start_i)
            irq4_latch <= 1'b1;
        if (gp_irq_clear_i)
            irq4_latch <= 1'b0;
    end
end

always_ff @(posedge clk) begin
    if (rst) begin
        coin_control_o <= 8'h00;
        last_program_fetch_o <= 24'h000000;
        bus_count_o <= 32'd0;
        rom_read_count_o <= 32'd0;
        wram_write_count_o <= 32'd0;
        shared_write_count_o <= 32'd0;
        gp_access_count_o <= 32'd0;
        palette_write_count_o <= 32'd0;
        unmapped_count_o <= 32'd0;
    end else begin
        if (ack_now) begin
            bus_count_o <= bus_count_o + 32'd1;
            if (normal_rom_read_cs) begin
                rom_read_count_o <= rom_read_count_o + 32'd1;
                if (cpu_program_space)
                    last_program_fetch_o <= cpu_addr8;
            end
            if (|wram_we)
                wram_write_count_o <= wram_write_count_o + 32'd1;
            if (shared_we)
                shared_write_count_o <= shared_write_count_o + 32'd1;
            if (gp_cs)
                gp_access_count_o <= gp_access_count_o + 32'd1;
            if (|palette_we)
                palette_write_count_o <= palette_write_count_o + 32'd1;
            if (unmapped_cs && !ss_special_cs)
                unmapped_count_o <= unmapped_count_o + 32'd1;
        end

        if (ss_restore_commit_i)
            coin_control_o <= ss_restore_coin_control_i;
        else if (ack_now && coin_cs && cpu_write && !cpu_lds_n)
            coin_control_o <= cpu_dout[7:0];
    end
end

endmodule
