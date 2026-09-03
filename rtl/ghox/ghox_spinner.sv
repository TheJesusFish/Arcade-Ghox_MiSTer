// Ghox parent relative-input adapter.
//
// Ordering at one clk edge:
//   1. an accepted CPU read consumes the position already committed;
//   2. a changed host toggle then applies once for the next read;
//   3. the selected source alone may move the accumulator.
// physical_enable and fallback_enable are intentionally exclusive in the
// parent integration.  They remain separate ports so the adapter's source
// isolation is directly testable.
module ghox_spinner #(
    parameter integer PHASE_WIDTH = 18,
    parameter integer FALLBACK_STEP = 4,
    parameter integer PHYSICAL_HOLDOFF_TICKS = 333334
) (
    input  wire                         clk,
    input  wire                         rst,
    input  wire                         ce_cpu,
    input  wire                         spinner_mode,
    input  wire                         physical_enable,
    input  wire                         fallback_enable,

    input  wire signed [7:0]            host_delta,
    input  wire                         host_toggle,
    input  wire                         fallback_step,
    input  wire                         fallback_right,
    input  wire                         cpu_read_accept,

    output logic                        read_valid,
    output logic signed [7:0]           read_delta,
    output wire signed [7:0]            cpu_delta,

    input  wire                         state_load,
    input  wire [7:0]                   state_current_in,
    input  wire [7:0]                   state_consumed_in,
    input  wire                         state_last_toggle_in,
    input  wire                         state_pending_in,
    input  wire                         state_physical_owner_in,
    input  wire [PHASE_WIDTH-1:0]       state_fallback_phase_in,
    input  wire [PHASE_WIDTH:0]         state_physical_holdoff_in,

    output logic [7:0]                  state_current_out,
    output logic [7:0]                  state_consumed_out,
    output logic                        state_last_toggle_out,
    output logic                        state_pending_out,
    output logic                        state_physical_owner_out,
    output logic [PHASE_WIDTH-1:0]      state_fallback_phase_out,
    output logic [PHASE_WIDTH:0]        state_physical_holdoff_out
);

logic [7:0] current_position;
logic [7:0] consumed_position;
logic       last_host_toggle;
logic       pending_event;
logic       physical_owner;
logic [PHASE_WIDTH-1:0] fallback_phase;
logic [PHASE_WIDTH:0] physical_holdoff;

wire new_host_event = host_toggle != last_host_toggle;
wire new_host_movement = physical_enable && new_host_event &&
                         (host_delta != 0);
localparam logic [PHASE_WIDTH:0] PHYSICAL_HOLDOFF_VALUE =
    (PHASE_WIDTH + 1)'(PHYSICAL_HOLDOFF_TICKS);
localparam logic [7:0] FALLBACK_STEP_VALUE = 8'(FALLBACK_STEP);

assign state_current_out = current_position;
assign state_consumed_out = consumed_position;
assign state_last_toggle_out = last_host_toggle;
assign state_pending_out = pending_event;
assign state_physical_owner_out = physical_owner;
assign state_fallback_phase_out = fallback_phase;
assign state_physical_holdoff_out = physical_holdoff;
assign cpu_delta = $signed(current_position - consumed_position);

always_ff @(posedge clk) begin
    read_valid <= 1'b0;

    if (rst) begin
        current_position <= 8'd0;
        consumed_position <= 8'd0;
        last_host_toggle <= host_toggle;
        pending_event <= 1'b0;
        physical_owner <= 1'b0;
        fallback_phase <= '0;
        physical_holdoff <= '0;
        read_delta <= 8'sd0;
    end else if (state_load) begin
        current_position <= state_current_in;
        consumed_position <= state_consumed_in;
        last_host_toggle <= state_last_toggle_in;
        pending_event <= state_pending_in;
        physical_owner <= state_physical_owner_in;
        fallback_phase <= state_fallback_phase_in;
        physical_holdoff <= state_physical_holdoff_in;
        read_delta <= 8'sd0;
    end else if (!spinner_mode) begin
        last_host_toggle <= host_toggle;
        pending_event <= 1'b0;
        physical_owner <= 1'b0;
        fallback_phase <= '0;
        physical_holdoff <= '0;
        read_delta <= 8'sd0;
    end else begin
        if (cpu_read_accept) begin
            read_valid <= 1'b1;
            read_delta <= $signed(current_position - consumed_position);
            consumed_position <= current_position;
            pending_event <= 1'b0;
        end

        // Always acknowledge a changed host toggle, including while physical
        // input is disabled and including zero-delta updates. Only selected,
        // actual movement may claim ownership; an old/noisy relative event
        // therefore cannot starve or replay into joystick mode.
        if (new_host_event)
            last_host_toggle <= host_toggle;

        if (new_host_movement) begin
            current_position <= current_position + host_delta;
            pending_event <= 1'b1;
            physical_owner <= 1'b1;
            fallback_phase <= '0;
            physical_holdoff <= PHYSICAL_HOLDOFF_VALUE;
        end else begin
            // The joystick source is the decoded JTFrame quadrature stream,
            // not a locally timed held-direction approximation.  Each valid
            // axis step is therefore applied once at its actual framework
            // boundary and remains visible until an accepted CPU read.
            if (fallback_enable && fallback_step) begin
                pending_event <= 1'b1;
                fallback_phase <= '0;
                if (fallback_right)
                    current_position <=
                        current_position + FALLBACK_STEP_VALUE;
                else
                    current_position <=
                        current_position - FALLBACK_STEP_VALUE;
            end

            if (ce_cpu) begin
                fallback_phase <= '0;
                if (!physical_enable) begin
                    physical_holdoff <= '0;
                    physical_owner <= 1'b0;
                end else if (physical_holdoff != 0) begin
                    physical_holdoff <= physical_holdoff - 1'b1;
                    if (physical_holdoff == 1)
                        physical_owner <= 1'b0;
                end
            end
        end
    end
end

initial begin
    if (PHYSICAL_HOLDOFF_TICKS >= (1 << (PHASE_WIDTH + 1)))
        $error("PHASE_WIDTH cannot hold physical holdoff");
    if (FALLBACK_STEP < 1 || FALLBACK_STEP > 127)
        $error("FALLBACK_STEP must fit positive signed byte");
end

endmodule
