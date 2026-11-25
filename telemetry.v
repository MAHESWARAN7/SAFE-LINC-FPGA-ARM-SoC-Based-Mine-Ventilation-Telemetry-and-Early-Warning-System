`timescale 1ns / 1ps

module telemetry_axil_ip #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 6,
    parameter integer CLK_FREQ_HZ        = 100_000_000,
    parameter [15:0]  TEMP_LIMIT_X10     = 16'd400,
    parameter [15:0]  MQ2_LIMIT          = 16'd700
)(
    input  wire                                  s_axi_aclk,
    input  wire                                  s_axi_aresetn,

    input  wire [C_S_AXI_ADDR_WIDTH-1 : 0]       s_axi_awaddr,
    input  wire                                  s_axi_awvalid,
    output reg                                   s_axi_awready,

    input  wire [C_S_AXI_DATA_WIDTH-1 : 0]       s_axi_wdata,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0]   s_axi_wstrb,
    input  wire                                  s_axi_wvalid,
    output reg                                   s_axi_wready,

    output reg  [1 : 0]                          s_axi_bresp,
    output reg                                   s_axi_bvalid,
    input  wire                                  s_axi_bready,

    input  wire [C_S_AXI_ADDR_WIDTH-1 : 0]       s_axi_araddr,
    input  wire                                  s_axi_arvalid,
    output reg                                   s_axi_arready,

    output reg  [C_S_AXI_DATA_WIDTH-1 : 0]       s_axi_rdata,
    output reg  [1 : 0]                          s_axi_rresp,
    output reg                                   s_axi_rvalid,
    input  wire                                  s_axi_rready,

    output reg                                   buzzer_out,
    output wire                                  fan_pwm_out
);

    reg [31:0] reg_temp_hum;
    reg [31:0] reg_mq2;
    reg [31:0] reg_fan_ctrl;

    wire [15:0] temp_x10     = reg_temp_hum[15:0];
    wire [15:0] mq2_raw      = reg_mq2[15:0];
    wire [7:0]  fan_override = reg_fan_ctrl[7:0];
    wire        auto_fan_en  = reg_fan_ctrl[8];

    wire temp_breach  = (temp_x10 > TEMP_LIMIT_X10);
    wire mq2_breach   = (mq2_raw  > MQ2_LIMIT);
    wire alert_active = temp_breach | mq2_breach;

    reg aw_en;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            aw_en         <= 1'b1;
            reg_temp_hum  <= 32'h0000_011D;
            reg_mq2       <= 32'h0000_0140;
            reg_fan_ctrl  <= 32'h0000_0123;
        end else begin
            if (~s_axi_awready && s_axi_awvalid && s_axi_wvalid && aw_en) begin
                s_axi_awready <= 1'b1;
                aw_en         <= 1'b0;
            end else begin
                s_axi_awready <= 1'b0;
                if (s_axi_bvalid && s_axi_bready)
                    aw_en <= 1'b1;
            end

            if (~s_axi_wready && s_axi_wvalid && s_axi_awvalid && aw_en) begin
                s_axi_wready <= 1'b1;
                case (s_axi_awaddr[5:2])
                    4'h0: if (s_axi_wstrb[0]) reg_temp_hum <= s_axi_wdata;
                    4'h1: if (s_axi_wstrb[0]) reg_mq2      <= s_axi_wdata;
                    4'h2: if (s_axi_wstrb[0]) reg_fan_ctrl <= s_axi_wdata;
                    default: ;
                endcase
            end else begin
                s_axi_wready <= 1'b0;
            end

            if (s_axi_awready && s_axi_awvalid && ~s_axi_bvalid && s_axi_wready && s_axi_wvalid) begin
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rresp   <= 2'b00;
            s_axi_rdata   <= 32'd0;
        end else begin
            if (~s_axi_arready && s_axi_arvalid) begin
                s_axi_arready <= 1'b1;
                case (s_axi_araddr[5:2])
                    4'h0: s_axi_rdata <= reg_temp_hum;
                    4'h1: s_axi_rdata <= reg_mq2;
                    4'h2: s_axi_rdata <= reg_fan_ctrl;
                    4'h3: s_axi_rdata <= {29'd0, mq2_breach, temp_breach, alert_active};
                    default: s_axi_rdata <= 32'd0;
                endcase
            end else begin
                s_axi_arready <= 1'b0;
            end

            if (s_axi_arready && s_axi_arvalid && ~s_axi_rvalid) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp  <= 2'b00;
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    localparam integer TOGGLE_TICKS = CLK_FREQ_HZ / 10;
    reg [31:0] buzz_cnt;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            buzz_cnt   <= 32'd0;
            buzzer_out <= 1'b0;
        end else if (alert_active) begin
            if (buzz_cnt >= TOGGLE_TICKS - 1) begin
                buzz_cnt   <= 32'd0;
                buzzer_out <= ~buzzer_out;
            end else begin
                buzz_cnt <= buzz_cnt + 1'b1;
            end
        end else begin
            buzz_cnt   <= 32'd0;
            buzzer_out <= 1'b0;
        end
    end

    localparam integer PWM_PERIOD = CLK_FREQ_HZ / 25_000;
    wire [7:0] active_duty = (auto_fan_en && alert_active) ? 8'd95 :
                             (fan_override > 8'd100 ? 8'd100 : fan_override);
    wire [31:0] high_ticks = (PWM_PERIOD * active_duty) / 100;
    reg  [31:0] pwm_cnt;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            pwm_cnt <= 32'd0;
        end else if (pwm_cnt >= PWM_PERIOD - 1) begin
            pwm_cnt <= 32'd0;
        end else begin
            pwm_cnt <= pwm_cnt + 1'b1;
        end
    end

    assign fan_pwm_out = (pwm_cnt < high_ticks);

endmodule