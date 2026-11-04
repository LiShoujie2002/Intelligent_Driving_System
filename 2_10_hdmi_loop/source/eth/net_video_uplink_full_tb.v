`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// net_video_uplink 全尺寸仿真（和板子完全一样的参数）
//
//   源 1280×720 → 上传 640×360，NPIX=230400，DATA_PER=1440（320 包/帧），
//   PKT_GAP=11000。只统计：发了几帧、有没有 bank 冲突、采集有没有停摆。
//
//   小尺寸仿真通过了但板子上不发，所以要把尺寸拉到和硬件一致再验一次，
//   排除地址位宽这类只在大尺寸下才暴露的问题。
//
//   编译: iverilog -g2012 -o full_tb net_video_uplink_full_tb.v net_video_uplink.v \
//                        eth_udp_video_tx.v eth_udp_tx.v eth_frame_tx.v video_downsample.v
//////////////////////////////////////////////////////////////////////////////////

module net_video_uplink_full_tb;

    localparam SRC_W = 1280;
    localparam SRC_H = 720;
    localparam IMG_W = 640;
    localparam IMG_H = 360;

    localparam HT = 1650;
    localparam VT = 724;          // 消隐 4 行 ×1650 = 6600 > GAP_THRESH 5000

    reg pix_clk = 0;
    reg net_clk = 0;
    always #5 pix_clk = ~pix_clk;
    always #4 net_clk = ~net_clk;

    reg pix_rstn = 0;
    reg net_rstn = 0;

    reg        de = 0;
    reg [7:0]  r = 8'h40, g = 8'h40, b = 8'h40;
    reg [10:0] vx = 0, vy = 0;

    wire tx_en;
    wire [7:0] txd;
    wire [31:0] frame_cnt;
    wire link_busy;

    always @(negedge pix_clk) begin
        if(!pix_rstn) begin
            vx <= 0; vy <= 0; de <= 0;
        end
        else begin
            if(vx == HT-1) begin
                vx <= 0;
                vy <= (vy == VT-1) ? 11'd0 : vy + 1;
            end
            else vx <= vx + 1;
            de <= (vx < SRC_W) && (vy < SRC_H);
        end
    end

    net_video_uplink #(
        .IMG_W ( IMG_W ), .IMG_H ( IMG_H ),
        .SRC_W ( SRC_W ), .SRC_H ( SRC_H )
    ) dut (
        .pix_clk   ( pix_clk  ),
        .pix_rstn  ( pix_rstn ),
        .de_in     ( de       ),
        .r_in      ( r        ),
        .g_in      ( g        ),
        .b_in      ( b        ),
        .net_clk   ( net_clk  ),
        .net_rstn  ( net_rstn ),
        .tx_en     ( tx_en    ),
        .txd       ( txd      ),
        .frame_cnt ( frame_cnt ),
        .link_busy ( link_busy )
    );

    integer sent = 0;
    integer violations = 0;
    integer caps = 0;

    always @(posedge pix_clk) begin
        if(pix_rstn && dut.cap_en && link_busy && (dut.wr_bank == dut.rd_bank)) begin
            violations = violations + 1;
            if(violations <= 3)
                $display("  !! bank 冲突 t=%0t", $time);
        end
        if(pix_rstn && dut.cap_fin) caps = caps + 1;
    end

    always @(posedge net_clk) begin
        if(net_rstn && dut.u_video.frame_done) begin
            sent = sent + 1;
            if(sent <= 10)
                $display("  t=%0t  已发送 %0d 帧", $time, sent);
        end
    end

    initial begin
        #100 pix_rstn = 1;
        repeat (5 * HT * VT) @(negedge pix_clk);
        $display("  像素域先跑了 5 帧，现在放开网络域复位");
        net_rstn = 1;

        repeat (8 * HT * VT) @(negedge pix_clk);

        $display("");
        $display("  采集完成        : %0d 帧", caps);
        $display("  发送完成        : %0d 帧", sent);
        $display("  bank 冲突       : %0d", violations);
        $display("  frame_cnt       : %0d", frame_cnt);
        if(sent >= 3 && violations == 0) $display("RESULT: PASS");
        else                             $display("RESULT: FAIL");
        $finish;
    end

endmodule
