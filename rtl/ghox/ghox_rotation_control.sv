// SPDX-License-Identifier: BSD-3-Clause

// Ghox-local decoder for the MiSTer scaler framebuffer rotation menu.
//
// The native raster is counter-clockwise.  The default 00 choice rotates it
// into an upright portrait image through the screen_rotate CCW mode used by
// this core.  The two "No" choices either leave
// the native raster alone (01) or use screen_rotate's 180-degree framebuffer
// flip (10).  Direct video cannot consume the scaler framebuffer, so it
// disables both rotation and flip.
module ghox_rotation_control (
    input  logic [1:0] menu,
    input  logic       direct_video,
    output logic       rotate_enabled,
    output logic       rotate_ccw,
    output logic       no_rotate,
    output logic       framebuf_flip,
    output logic       menu_disabled
);

always_comb begin
    rotate_enabled = !direct_video && (menu == 2'b00);
    rotate_ccw      = 1'b1;
    no_rotate       = !rotate_enabled;
    framebuf_flip   = !direct_video && (menu == 2'b10);
    menu_disabled   = direct_video;
end

endmodule
