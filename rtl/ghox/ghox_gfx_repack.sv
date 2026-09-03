// Map the preserved GP9001 renderer's logical plane address onto Ghox's
// cache-line-interleaved 512 KiB graphics ROM pair.
//
// The renderer names the upper two bitplanes with logical bit 19
// (0x80000 16-bit words). The exact MRA places each lower/upper plane word
// pair in one 32-bit SDRAM block, so logical bit 19 becomes physical bit 0.
// A lower-plane read fills the block cache and the following upper-plane
// read hits its adjacent word.
//
// MAME 0.288's GP9001 layouts decode this region as 8192 16x16 tiles or
// 32768 8x8 sprite elements and wrap element codes to that population.
// Logical bit 18 is the first excess code bit for both renderer views, so
// dropping it implements the same power-of-two modulo. Bits 21:20 are outside
// the GP9001 renderer contract and remain invalid.
module ghox_gfx_repack (
    input  logic [21:0] logical_addr_i,
    output logic [18:0] physical_addr_o,
    output logic        valid_o
);

assign physical_addr_o = {logical_addr_i[17:0], logical_addr_i[19]};
assign valid_o = logical_addr_i[21:20] == 2'b00;

endmodule
