// Exact TP-021 MC68000 word-bus decode pinned to MAME 0.288 ghox.cpp.
module ghox_main_decode (
    input  logic [23:0] addr,
    input  logic        bus_active,
    input  logic        rw,

    output logic rom_cs,
    output logic rom_read_cs,
    output logic p2_analog_cs,
    output logic wram_cs,
    output logic palette_cs,
    output logic p1_analog_cs,
    output logic gp_cs,
    output logic shared_cs,
    output logic coin_cs,
    output logic region_cs,
    output logic mapped_cs,
    output logic unmapped_cs
);

logic read_cycle;
assign read_cycle = bus_active && rw;

assign rom_cs       = bus_active && addr < 24'h040000;
assign rom_read_cs  = rom_cs && rw;
assign p2_analog_cs = read_cycle && ((addr & 24'hfffffe) == 24'h040000);
assign wram_cs      = bus_active &&
                      addr >= 24'h080000 && addr < 24'h084000;
assign palette_cs   = bus_active &&
                      addr >= 24'h0c0000 && addr < 24'h0c1000;
assign p1_analog_cs = read_cycle && ((addr & 24'hfffffe) == 24'h100000);
assign gp_cs        = bus_active &&
                      addr >= 24'h140000 && addr < 24'h14000e;
assign shared_cs    = bus_active &&
                      addr >= 24'h180000 && addr < 24'h181000;
// fx68k exposes word-aligned addresses. The real byte register is at 181001
// and is qualified by LDSn in ghox_main.
assign coin_cs      = bus_active &&
                      ((addr & 24'hfffffe) == 24'h181000);
assign region_cs    = read_cycle &&
                      ((addr & 24'hfffffe) == 24'h18100c);

assign mapped_cs = rom_cs || p2_analog_cs || wram_cs || palette_cs ||
                   p1_analog_cs || gp_cs || shared_cs || coin_cs ||
                   region_cs;
assign unmapped_cs = bus_active && !mapped_cs;

endmodule
