// SPDX-License-Identifier: BSD-3-Clause

// Ghox-local adaptation of Batsugun's framebuffer-window crop helper.
module ghox_rotated_crop #(
    parameter [11:0] CROP_HEIGHT = 12'd270
) (
    input                    enable,
    input signed       [4:0] offset,
    input             [11:0] width_in,
    input             [11:0] height_in,
    input             [31:0] base_in,
    input             [13:0] stride_in,
    output                   active,
    output            [11:0] width_out,
    output            [11:0] height_out,
    output            [31:0] base_out
);

// screen_rotate has changed the portrait axis into framebuffer rows. Crop by
// moving the read window without changing framebuffer contents or stride.
wire [11:0] margin = height_in >= CROP_HEIGHT ?
                     height_in - CROP_HEIGHT : 12'd0;
wire [11:0] center = margin >> 1;
wire signed [12:0] requested = $signed({1'b0, center}) +
                               $signed({{8{offset[4]}}, offset});
wire [11:0] start_line = requested[12] ? 12'd0 :
                         (requested > $signed({1'b0, margin})) ? margin :
                         requested[11:0];
wire [25:0] base_offset = start_line * stride_in;

assign active     = enable && (height_in >= CROP_HEIGHT);
assign width_out  = width_in;
assign height_out = active ? CROP_HEIGHT : height_in;
assign base_out   = active ? base_in + {6'd0, base_offset} : base_in;

endmodule
