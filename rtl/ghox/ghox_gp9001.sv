// Ghox single-GP9001 integration wrapper.
//
// The implementation is the protected, unchanged Dogyuun donor block whose
// CPU/register/VRAM semantics were selected in the bootstrap source audit.
// This wrapper gives the Ghox core its own stable boundary without forking
// that protected source.
module ghox_gp9001 (
    input  logic         clk,
    input  logic         rst,

    input  logic         start_i,
    input  logic         rw_i,
    input  logic [3:0]   addr_i,
    input  logic [15:0]  din_i,
    input  logic [1:0]   we_i,
    input  logic         status_bit_i,
    output logic         busy_o,
    output logic         done_o,
    output logic [15:0]  dout_o,
    output logic         irq_clear_o,

    input  logic [12:0]  scan_addr_i,
    output logic [15:0]  scan_dout_o,
    input  logic         obj_buf_start_i,
    input  logic [9:0]   obj_scan_addr_i,
    output logic [15:0]  obj_scan_dout_o,
    output logic         obj_buf_busy_o,
    output logic         obj_buf_miss_o,
    output logic [12:0]  ptr_o,
    output logic [7:0]   scroll_select_o,
    output logic [127:0] scrolls_o,
    output logic [7:0]   scroll_flip_o,
    output logic         vram_write_o,
    output logic         scroll_write_o,

    input  logic         ss_hold_i,
    input  logic         ss_restore_enable_i,
    input  logic [63:0]  ss_data_i,
    input  logic [31:0]  ss_addr_i,
    input  logic [7:0]   ss_select_i,
    input  logic         ss_write_i,
    input  logic         ss_read_i,
    input  logic         ss_query_i,
    output logic [63:0]  ss_data_o,
    output logic         ss_ack_o
);

dogyuun_gp9001_cpu #(
    .SS_RAM_IDX  (8'd5),
    .SS_REG_IDX  (8'd6),
    .SS_OBJ0_IDX (8'd7),
    .SS_OBJ1_IDX (8'd8)
) u_preserved_gp9001 (
    .clk               (clk),
    .rst               (rst),
    .start             (start_i),
    .rw                (rw_i),
    .addr              (addr_i),
    .din               (din_i),
    .we_mask           (we_i),
    .status_bit        (status_bit_i),
    .busy              (busy_o),
    .done              (done_o),
    .dout              (dout_o),
    .irq_clear         (irq_clear_o),
    .scan_addr         (scan_addr_i),
    .scan_dout         (scan_dout_o),
    .obj_buf_start     (obj_buf_start_i),
    .obj_scan_addr     (obj_scan_addr_i),
    .obj_scan_dout     (obj_scan_dout_o),
    .obj_buf_busy      (obj_buf_busy_o),
    .obj_buf_miss      (obj_buf_miss_o),
    .dbg_ptr           (ptr_o),
    .dbg_scroll_select (scroll_select_o),
    .scrolls           (scrolls_o),
    .scroll_flip       (scroll_flip_o),
    .vram_write        (vram_write_o),
    .scroll_write      (scroll_write_o),
    .ss_hold           (ss_hold_i),
    .ss_restore_enable (ss_restore_enable_i),
    .ss_data           (ss_data_i),
    .ss_addr           (ss_addr_i),
    .ss_select         (ss_select_i),
    .ss_write          (ss_write_i),
    .ss_read           (ss_read_i),
    .ss_query          (ss_query_i),
    .ss_data_out       (ss_data_o),
    .ss_ack            (ss_ack_o)
);

endmodule
