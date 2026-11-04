`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// osd_overlay 自检：四个类别各一个框，统计序号区域画出来的像素
//
//   采样点用 DUT 内部的 dut.x / dut.y —— 输出是组合的，哪个像素就按哪个坐标算，
//   这样不受 TB 自己驱动 de 的那一拍错位影响。
//
//   * 前景像素数 > 0      说明序号画出来了
//   * 前景颜色 == 类别色  说明颜色对
//   * 其余像素全黑        说明底色对
//////////////////////////////////////////////////////////////////////////////////
module osd_overlay_tb;

    localparam NBOX = 32;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg         rstn  = 1'b0;
    reg         de_in = 1'b0;
    reg  [7:0]  r_in = 8'h80, g_in = 8'h80, b_in = 8'h80;

    wire        de_out;
    wire [7:0]  r_out, g_out, b_out;

    reg  [7:0]         nbox;
    reg  [NBOX*16-1:0] bx1, by1, bx2, by2;
    reg  [NBOX*8-1:0]  bcls;
    reg  [NBOX*8-1:0]  bsub;

    osd_overlay #(.NBOX(NBOX)) dut (
        .pix_clk(clk), .rstn(rstn),
        .de_in(de_in), .r_in(r_in), .g_in(g_in), .b_in(b_in),
        .enable(1'b1), .nbox(nbox),
        .bx1(bx1), .by1(by1), .bx2(bx2), .by2(by2), .bcls(bcls), .bsub(bsub),
        .de_out(de_out), .r_out(r_out), .g_out(g_out), .b_out(b_out)
    );

    // 四个框的坐标和类别（在 initial 里填，iverilog 老版本不支持数组常量初始化）
    integer BX [0:3];
    integer BY [0:3];
    integer CLS[0:3];

    task set_box(input integer i, input [15:0] x1, y1, x2, y2, input [7:0] c);
        begin
            bx1[i*16 +: 16] = x1; by1[i*16 +: 16] = y1;
            bx2[i*16 +: 16] = x2; by2[i*16 +: 16] = y2;
            bcls[i*8 +: 8]  = c;
            // 交通灯（类别 2）这里给"绿灯"，验证按灯色上色的通路
            bsub[i*8 +: 8]  = (c == 8'd2) ? 8'd3 : 8'd0;
        end
    endtask

    integer i, py, px;
    integer nfg   [0:3];
    integer nbg   [0:3];
    integer bad   [0:3];

    reg [7:0] er, eg, eb;

    // 每个像素采样一次：按 dut.x / dut.y 归到某个框的序号区域
    task sample;
        begin
            for(i = 0; i < 4; i = i + 1) begin
                if( (dut.x >= BX[i]) && (dut.x < BX[i] + 16) &&
                    (dut.y >= BY[i] - 17) && (dut.y < BY[i] - 1) ) begin
                    case(CLS[i])
                        0: begin er = 8'd0;   eg = 8'd255; eb = 8'd0;   end
                        1: begin er = 8'd255; eg = 8'd255; eb = 8'd0;   end
                        2: begin er = 8'd0;   eg = 8'd255; eb = 8'd0;   end  // 灯色=绿
                        default: begin er = 8'd255; eg = 8'd255; eb = 8'd255; end
                    endcase
                    if( (r_out == er) && (g_out == eg) && (b_out == eb) )
                        nfg[i] = nfg[i] + 1;
                    else if( (r_out == 8'd0) && (g_out == 8'd0) && (b_out == 8'd0) )
                        nbg[i] = nbg[i] + 1;
                    else
                        bad[i] = bad[i] + 1;
                end
            end
        end
    endtask

    initial begin
        BX[0] = 100; BX[1] = 400; BX[2] = 700; BX[3] = 1000;
        BY[0] = 100; BY[1] = 100; BY[2] = 100; BY[3] = 400;
        CLS[0] = 0;  CLS[1] = 1;  CLS[2] = 2;  CLS[3] = 3;

        nbox = 4;
        bx1 = 0; by1 = 0; bx2 = 0; by2 = 0; bcls = 0;
        for(i = 0; i < 4; i = i + 1) begin
            set_box(i, BX[i], BY[i], BX[i] + 200, BY[i] + 200, CLS[i]);
            nfg[i] = 0; nbg[i] = 0; bad[i] = 0;
        end

        repeat(4) @(posedge clk);
        rstn <= 1'b1;
        repeat(2) @(posedge clk);

        // 框表在帧消隐期锁存：先给一段消隐，把表锁进显示寄存器
        de_in = 1'b0;
        repeat(5200) @(posedge clk);

        // 光栅 620 行；行间消隐 20 拍（小于 GAP_THR，y 靠 de 下降沿累加）
        for(py = 0; py < 620; py = py + 1) begin
            for(px = 0; px < 1280; px = px + 1) begin
                de_in = 1'b1;
                @(posedge clk);
                #1;
                sample;
            end
            de_in = 1'b0;
            repeat(20) @(posedge clk);
        end
        #1;

        $display("---- 序号渲染结果 ----");
        for(i = 0; i < 4; i = i + 1)
            $display("  类别 %0d @(%0d,%0d):  前景 %0d px  黑底 %0d px  异常 %0d px",
                     CLS[i], BX[i], BY[i], nfg[i], nbg[i], bad[i]);

        if( (nfg[0] > 0) && (nfg[1] > 0) && (nfg[2] > 0) && (nfg[3] > 0) &&
            (bad[0] == 0) && (bad[1] == 0) && (bad[2] == 0) && (bad[3] == 0) )
            $display("PASS");
        else
            $display("FAIL");
        $finish;
    end

endmodule
