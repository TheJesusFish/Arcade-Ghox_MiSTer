// Exact TP-021 enables and raster for a 94.5 MHz master clock.
module ghox_timing (
    input  logic        clk,
    input  logic        rst,
    output logic        pixel2_cen_o,
    output logic        pixel_cen_o,
    output logic        opm_cen_o,
    output logic        sound_cpu_cen_o,
    output logic [9:0]  hcnt_o,
    output logic [8:0]  vcnt_o,
    output logic        video_epoch_o,
    output logic        line_start_o,
    output logic        line_commit_o,
    output logic [8:0]  line_target_y_o,
    output logic        line_target_epoch_o,
    output logic        object_buffer_start_o,
    output logic        irq4_start_o,
    output logic        gp_status_o,
    output logic        frame_tick_o
);

localparam logic [9:0] H_TOTAL = 10'd432;
localparam logic [8:0] V_TOTAL = 9'd262;

logic [3:0] pixel_div = 4'd0;
logic [4:0] opm_div = 5'd0;
logic [7:0] sound_accum = 8'd0;

assign pixel_cen_o = pixel_div == 4'd13;
assign pixel2_cen_o = (pixel_div == 4'd6) || pixel_cen_o;
assign opm_cen_o = opm_div == 5'd27;
assign sound_cpu_cen_o =
    ({1'b0, sound_accum} + 9'd20) >= 9'd189;

wire line_event = pixel_cen_o && hcnt_o == H_TOTAL - 1'b1;
assign line_start_o = line_event &&
                      ((vcnt_o < 9'd238) || (vcnt_o >= 9'd260));
assign line_commit_o = line_event &&
                       ((vcnt_o < 9'd239) ||
                        (vcnt_o == V_TOTAL - 1'b1));
assign line_target_y_o = (vcnt_o >= 9'd260) ?
                         vcnt_o - 9'd260 : vcnt_o + 9'd2;
assign line_target_epoch_o = (vcnt_o >= 9'd260) ?
                             ~video_epoch_o : video_epoch_o;
assign object_buffer_start_o = line_event && vcnt_o == 9'd239;
assign irq4_start_o = pixel_cen_o &&
                      hcnt_o == 10'd0 && vcnt_o == 9'd230;
assign frame_tick_o = line_event && vcnt_o == V_TOTAL - 1'b1;

wire [9:0] gp_status_sum = {1'b0, vcnt_o} + 10'd15;
wire [9:0] gp_status_v = (gp_status_sum >= 10'd262) ?
                         gp_status_sum - 10'd262 : gp_status_sum;
assign gp_status_o = gp_status_v >= 10'd245;

always_ff @(posedge clk) begin
    if (rst) begin
        pixel_div <= 4'd0;
        opm_div <= 5'd0;
        sound_accum <= 8'd0;
    end else begin
        pixel_div <= pixel_cen_o ? 4'd0 : pixel_div + 1'b1;
        opm_div <= opm_cen_o ? 5'd0 : opm_div + 1'b1;
        if (sound_cpu_cen_o) begin
            sound_accum <= sound_accum + 8'd20 - 8'd189;
        end else begin
            sound_accum <= sound_accum + 8'd20;
        end
    end
end

always_ff @(posedge clk) begin
    if (rst) begin
        hcnt_o <= 10'd0;
        vcnt_o <= 9'd0;
        video_epoch_o <= 1'b0;
    end else if (pixel_cen_o) begin
        if (hcnt_o == H_TOTAL - 1'b1) begin
            hcnt_o <= 10'd0;
            if (vcnt_o == V_TOTAL - 1'b1) begin
                vcnt_o <= 9'd0;
                video_epoch_o <= ~video_epoch_o;
            end else begin
                vcnt_o <= vcnt_o + 1'b1;
            end
        end else begin
            hcnt_o <= hcnt_o + 1'b1;
        end
    end
end

endmodule
