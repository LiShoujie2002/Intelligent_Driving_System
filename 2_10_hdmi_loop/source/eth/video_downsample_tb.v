`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// video_downsample 自检
//
//   用小尺寸帧（64×32）跑两个完整帧，检查第二帧的输出。
//   源图与 eth_ds_test 一致：r = x, g = y, b = (7x + 13y) & 0xFF
//   期望输出 = 每个 2×2 块的均值，转 RGB565
//
//   编译: iverilog -o ds_tb video_downsample_tb.v video_downsample.v
//   运行: vvp ds_tb
//////////////////////////////////////////////////////////////////////////////////

module video_downsample_tb;

    localparam HA = 64;      // 有效宽
    localparam VA = 32;      // 有效高
    localparam HT = 80;      // 总宽（含消隐）
    localparam VT = 40;      // 总高（含消隐，垂直消隐 8 行 = 640 拍）
    localparam GAP = 300;    // > 水平消隐 16，< 垂直消隐 640

    reg          clk = 0;
    reg          rstn = 0;
    reg          de = 0;
    reg  [7:0]   r = 0, g = 0, b = 0;

    wire         ds_de;
    wire [15:0]  ds_rgb;
    wire [9:0]   ds_x, ds_y;
    wire         ds_sync;

    video_downsample #(
        .H_ACT      ( HA  ),
        .V_ACT      ( VA  ),
        .GAP_THRESH ( GAP )
    ) dut (
        .clk        ( clk     ),
        .rstn       ( rstn    ),
        .de_in      ( de      ),
        .r_in       ( r       ),
        .g_in       ( g       ),
        .b_in       ( b       ),
        .de_out     ( ds_de   ),
        .rgb_out    ( ds_rgb  ),
        .x_out      ( ds_x    ),
        .y_out      ( ds_y    ),
        .frame_sync ( ds_sync )
    );

    always #5 clk = ~clk;

    //------------------------------------------------------------------
    //  期望值：块 (bx,by) 的 2×2 均值
    //------------------------------------------------------------------
    function [15:0] expect_px;
        input integer bx;
        input integer by;
        integer x0, y0, ar, ag, ab;
        begin
            x0 = bx * 2;
            y0 = by * 2;
            ar = (x0 + (x0+1) + x0 + (x0+1)) / 4;            // r = x
            ag = (y0 + y0 + (y0+1) + (y0+1)) / 4;            // g = y
            ab = (((7*x0       + 13*y0      ) & 255)
                + ((7*(x0+1)   + 13*y0      ) & 255)
                + ((7*x0       + 13*(y0+1)  ) & 255)
                + ((7*(x0+1)   + 13*(y0+1)  ) & 255)) / 4;
            expect_px = {ar[7:3], ag[7:2], ab[7:3]};
        end
    endfunction

    //------------------------------------------------------------------
    //  检查（跳过第一帧，行缓存此时还没填过）
    //------------------------------------------------------------------
    integer frames = 0;
    integer errs = 0;
    integer outs = 0;
    reg [9:0] maxx = 0, maxy = 0;

    always @(posedge clk) begin
        if(ds_sync) frames <= frames + 1;
    end

    always @(posedge clk) begin
        if(ds_de) begin
            outs = outs + 1;
            if(ds_x > maxx) maxx <= ds_x;
            if(ds_y > maxy) maxy <= ds_y;
            if(frames >= 1) begin
                if(ds_y == 0 && ds_x < 4)
                    $display("  out(%0d,%0d) got=%h | A(lb_d1)=%h B(lb_rd)=%h C(cur_d2)=%h D(cur_d1)=%h",
                             ds_x, ds_y, ds_rgb,
                             dut.lb_d1, dut.lb_rdata, dut.cur_d2, dut.cur_d1);
                if(ds_rgb !== expect_px(ds_x, ds_y)) begin
                    if(errs < 12)
                        $display("  MISMATCH out(%0d,%0d) got=%h exp=%h",
                                 ds_x, ds_y, ds_rgb, expect_px(ds_x, ds_y));
                    errs = errs + 1;
                end
            end
        end
    end

    //------------------------------------------------------------------
    //  视频源
    //------------------------------------------------------------------
    reg [10:0] vx, vy;

    always @(negedge clk) begin
        if(!rstn) begin
            vx <= 0; vy <= 0; de <= 0; r <= 0; g <= 0; b <= 0;
        end
        else begin
            if(vx == HT-1) begin
                vx <= 0;
                vy <= (vy == VT-1) ? 11'd0 : vy + 1;
            end
            else vx <= vx + 1;

            de <= (vx < HA) && (vy < VA);
            r  <= vx[7:0];
            g  <= vy[7:0];
            b  <= (vx[7:0] * 8'd7) + (vy[7:0] * 8'd13);
        end
    end

    //------------------------------------------------------------------
    initial begin
        #50 rstn = 1;
        // 跑够 3 帧
        repeat (3 * HT * VT) @(negedge clk);
        repeat (200) @(negedge clk);

        $display("");
        $display("  输出像素数 : %0d   (期望 %0d/帧)", outs, (HA/2)*(VA/2));
        $display("  最大坐标   : x=%0d y=%0d", maxx, maxy);
        $display("  见过的帧数 : %0d", frames);
        if(errs == 0)
            $display("RESULT: OK");
        else
            $display("RESULT: FAIL  错误 %0d 处", errs);
        $finish;
    end

endmodule
