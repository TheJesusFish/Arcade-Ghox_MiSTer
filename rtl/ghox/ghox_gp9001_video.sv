// Single-GP9001 Ghox line renderer.
//
// The tile and object engines are byte-identical preserved donor blocks.
// Ghox has one GP9001, so this wrapper applies only the per-GP priority rule
// from MAME 0.288: a nontransparent object pixel wins when its priority is
// greater than or equal to the tile pixel's priority.
module ghox_gp9001_video (
    input  logic         clk,
    input  logic         rst,
    input  logic         line_start_i,
    input  logic         line_commit_i,
    input  logic [8:0]   target_y_i,
    input  logic         target_epoch_i,
    input  logic [8:0]   display_x_i,
    input  logic [8:0]   display_y_i,
    input  logic         display_epoch_i,
    input  logic [127:0] scrolls_i,
    input  logic [7:0]   scroll_flip_i,

    output logic [12:0]  vram_addr_o,
    input  logic [15:0]  vram_data_i,
    output logic [9:0]   object_addr_o,
    input  logic [15:0]  object_data_i,

    output logic         tile_gfx_req_o,
    output logic [21:0]  tile_gfx_addr_o,
    input  logic [15:0]  tile_gfx_data_i,
    input  logic         tile_gfx_ok_i,
    output logic         object_gfx_req_o,
    output logic [21:0]  object_gfx_addr_o,
    input  logic [15:0]  object_gfx_data_i,
    input  logic         object_gfx_ok_i,

    output logic         line_ready_o,
    output logic [10:0]  color_o,
    output logic [1:0]   engine_busy_o,
    output logic [1:0]   engine_done_o,
    output logic [1:0]   deadline_miss_o,
    output logic [15:0]  tile_cycles_o,
    output logic [15:0]  object_cycles_o,
    output logic [8:0]   tile_line_y_o,
    output logic [8:0]   object_line_y_o,
    output logic [1:0]   line_epoch_o,
    output logic [1:0]   line_valid_o
);

logic [14:0] tile_pixel;
logic [14:0] object_pixel;
logic tile_epoch;
logic object_epoch;
logic tile_valid;
logic object_valid;
// The preserved tile engine consumes only scroll words 0-5 (bits 95:0).
// Holding an unused high bit at one guarantees its latched scroll vector
// changes on the first line after reset, which also makes older event-driven
// simulators evaluate the donor's derived-scroll always block deterministically.
wire [127:0] tile_scrolls = {1'b1, scrolls_i[126:0]};

ghox_gp9001_tile_line #(.GP_INDEX(0)) u_tile (
    .clk               (clk),
    .rst               (rst),
    .start             (line_start_i),
    .commit            (line_commit_i),
    .target_y          (target_y_i),
    .target_epoch      (target_epoch_i),
    .scrolls           (tile_scrolls),
    .scroll_flip       (scroll_flip_i),
    .busy              (engine_busy_o[0]),
    .done              (engine_done_o[0]),
    .deadline_miss     (deadline_miss_o[0]),
    .last_build_cycles (tile_cycles_o),
    .vram_addr         (vram_addr_o),
    .vram_data         (vram_data_i),
    .gfx_req           (tile_gfx_req_o),
    .gfx_addr          (tile_gfx_addr_o),
    .gfx_data          (tile_gfx_data_i),
    .gfx_ok            (tile_gfx_ok_i),
    .scan_x            (display_x_i),
    .scan_pixel        (tile_pixel),
    .scan_y            (tile_line_y_o),
    .scan_epoch        (tile_epoch),
    .scan_valid        (tile_valid)
);

ghox_gp9001_object_line #(.GP_INDEX(0)) u_object (
    .clk               (clk),
    .rst               (rst),
    .start             (line_start_i),
    .commit            (line_commit_i),
    .target_y          (target_y_i),
    .target_epoch      (target_epoch_i),
    .scrolls           (scrolls_i),
    .scroll_flip       (scroll_flip_i),
    .busy              (engine_busy_o[1]),
    .done              (engine_done_o[1]),
    .deadline_miss     (deadline_miss_o[1]),
    .last_build_cycles (object_cycles_o),
    .object_addr       (object_addr_o),
    .object_data       (object_data_i),
    .gfx_req           (object_gfx_req_o),
    .gfx_addr          (object_gfx_addr_o),
    .gfx_data          (object_gfx_data_i),
    .gfx_ok            (object_gfx_ok_i),
    .scan_x            (display_x_i),
    .scan_pixel        (object_pixel),
    .scan_y            (object_line_y_o),
    .scan_epoch        (object_epoch),
    .scan_valid        (object_valid)
);

assign line_epoch_o = {object_epoch, tile_epoch};
assign line_valid_o = {object_valid, tile_valid};
assign line_ready_o = tile_valid && object_valid &&
                      tile_line_y_o == display_y_i &&
                      object_line_y_o == display_y_i &&
                      tile_epoch == display_epoch_i &&
                      object_epoch == display_epoch_i;

logic [14:0] mixed_pixel;
always_comb begin
    if (object_pixel[3:0] != 4'h0 &&
        object_pixel[14:11] >= tile_pixel[14:11])
        mixed_pixel = object_pixel;
    else
        mixed_pixel = tile_pixel;
end

assign color_o = line_ready_o ? mixed_pixel[10:0] : 11'd0;

endmodule
