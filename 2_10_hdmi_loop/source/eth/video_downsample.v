`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: video_downsample
// Description: 1280×720 RGB888 → 640×360 RGB565（÷2 抽取 + 2×2 均值滤波）
//
//   【为什么先滤波再抽取】
//   直接取每 2×2 块的左上角会产生严重混叠（锯齿、摩尔纹），而模型是在
//   平滑缩放的图上训练的，混叠会造成 domain shift。2×2 均值只要 3 个加法器
//   和一次右移，代价极低。
//
//   【结构】
//   两条行缓存（乒乓），存上一行的 24bit 像素。处理第 y 行时读第 y-1 行。
//     写缓冲 = y[0]，读缓冲 = ~y[0]，读写不冲突。
//
//   【2×2 窗口对齐】
//   BRAM 读有 1 拍延迟，所以：
//     t    : 输入 (x,y)，同时给出行缓存读地址 x
//     t+1  : 行缓存数据 = (x, y-1)
//   再配两个寄存器延迟，凑齐四个角：
//     A = (x-1, y-1)   B = (x, y-1)
//     C = (x-1, y)     D = (x, y)
//   在 x 为奇数、y 为奇数时输出一个平均像素。
//
//   【行/帧同步】
//   MS7200 不输出 vs，所以行号靠 de 下降沿累加，帧边界靠 de 长时间拉低判定
//   （与 video_timing.v 的做法一致）。
//
//////////////////////////////////////////////////////////////////////////////////

module video_downsample #(
    parameter H_ACT      = 1280,      // 输入有效宽度
    parameter V_ACT      = 720,       // 输入有效高度
    // de 连续低这么多拍即判定为帧间隔。必须同时满足：
    //   远大于水平消隐（720p 约 370 拍）          -> 不会把行间消隐当成帧间隔
    //   远小于垂直消隐（720p 约 30 行 × 1650 ≈ 5 万拍）-> 一定能在帧间隔内触发
    // 取 5000 拍（40 us @125MHz）两头都留有余量。
    parameter GAP_THRESH = 5_000
)(
    input               clk,          // 像素时钟
    input               rstn,

    // ---- 输入（像素域）----
    input               de_in,
    input      [7:0]    r_in,
    input      [7:0]    g_in,
    input      [7:0]    b_in,

    // ---- 输出（RGB565，每个 2×2 块一个像素）----
    output reg          de_out,
    output     [15:0]   rgb_out,
    output reg [9:0]    x_out,        // 0 .. H_ACT/2-1
    output reg [9:0]    y_out,        // 0 .. V_ACT/2-1
    output reg          frame_sync    // 每帧第一个有效像素处一个脉冲
);

    localparam AW  = 11;              // 行缓存地址位宽（2048 > 1280）
    localparam LW  = 24;              // 每像素 24 bit

    //==========================================================================
    //  行 / 列计数
    //==========================================================================
    reg [AW:0]  x;                    // 当前行内的像素序号
    reg [10:0]  y;                    // 当前行号
    reg         de_d;
    reg [19:0]  gap_cnt;              // de 连续为低的拍数
    reg         vs_flag;              // 帧起始（de 重新拉高后的第一拍）

    wire line_end = de_d && !de_in;

    always @(posedge clk) begin
        if(!rstn) begin
            x       <= {(AW+1){1'b0}};
            y       <= 11'd0;
            de_d    <= 1'b0;
            gap_cnt <= 20'd0;
            vs_flag <= 1'b0;
        end
        else begin
            de_d <= de_in;

            if(de_in)
                x <= x + 1'b1;
            else
                x <= {(AW+1){1'b0}};

            if(line_end)
                y <= y + 11'd1;

            // 帧边界：de 长时间为低
            if(!de_in) begin
                if(gap_cnt != 20'hF_FFFF)
                    gap_cnt <= gap_cnt + 1'b1;
                // 在消隐期内就把行号清零，不要拖到新帧第一个像素那一拍，
                // 否则清零和 frame_sync 判定会挤在同一个时钟沿上。
                if(gap_cnt >= GAP_THRESH) begin
                    vs_flag <= 1'b1;
                    y       <= 11'd0;
                end
            end
            else begin
                gap_cnt <= 20'd0;
                vs_flag <= 1'b0;
            end
        end
    end

    //==========================================================================
    //  乒乓行缓存
    //==========================================================================
    reg [LW-1:0] lbuf0 [0:(1<<AW)-1];
    reg [LW-1:0] lbuf1 [0:(1<<AW)-1];

    wire        wsel = y[0];          // 当前行写入哪个缓冲
    wire        rsel = ~y[0];         // 上一行在另一个缓冲
    wire [AW-1:0] wa = x[AW-1:0];
    wire [AW-1:0] ra = x[AW-1:0];

    reg  [LW-1:0] lb_rdata;

    always @(posedge clk) begin
        if(de_in) begin
            if(wsel) lbuf1[wa] <= {r_in, g_in, b_in};
            else     lbuf0[wa] <= {r_in, g_in, b_in};
        end
    end

    always @(posedge clk) begin
        if(de_in) begin
            if(rsel) lb_rdata <= lbuf1[ra];
            else     lb_rdata <= lbuf0[ra];
        end
    end

    //==========================================================================
    //  对齐：凑齐 2×2 的四个角
    //==========================================================================
    reg [LW-1:0] cur_d1, cur_d2;      // 当前行延迟 1 / 2 拍
    reg [LW-1:0] lb_d1;               // 上一行延迟 1 拍
    reg [AW:0]   x_d1;
    reg          de_d1, de_d2, de_d3;
    reg          yd1_odd;

    always @(posedge clk) begin
        if(!rstn) begin
            cur_d1 <= 24'd0; cur_d2 <= 24'd0; lb_d1 <= 24'd0;
            x_d1   <= {(AW+1){1'b0}};
            de_d1  <= 1'b0;  de_d2  <= 1'b0; de_d3 <= 1'b0;
            yd1_odd<= 1'b0;
        end
        else begin
            cur_d1 <= {r_in, g_in, b_in};
            cur_d2 <= cur_d1;
            lb_d1  <= lb_rdata;
            x_d1   <= x;
            de_d1  <= de_in;
            de_d2  <= de_d1;
            de_d3  <= de_d2;
            yd1_odd<= y[0];
        end
    end

    // 此刻：
    //   cur_d2 = (x-1, y)   cur_d1 = (x, y)
    //   lb_d1  = (x-1,y-1)  lb_rdata = (x, y-1)
    wire [7:0] a_r = lb_d1[23:16],    b_r = lb_rdata[23:16];
    wire [7:0] c_r = cur_d2[23:16],   d_r = cur_d1[23:16];
    wire [7:0] a_g = lb_d1[15:8],     b_g = lb_rdata[15:8];
    wire [7:0] c_g = cur_d2[15:8],    d_g = cur_d1[15:8];
    wire [7:0] a_b = lb_d1[7:0],      b_b = lb_rdata[7:0];
    wire [7:0] c_b = cur_d2[7:0],     d_b = cur_d1[7:0];

    wire [9:0] s_r = {2'd0, a_r} + {2'd0, b_r} + {2'd0, c_r} + {2'd0, d_r};
    wire [9:0] s_g = {2'd0, a_g} + {2'd0, b_g} + {2'd0, c_g} + {2'd0, d_g};
    wire [9:0] s_b = {2'd0, a_b} + {2'd0, b_b} + {2'd0, c_b} + {2'd0, d_b};

    wire [7:0] avg_r = s_r[9:2];
    wire [7:0] avg_g = s_g[9:2];
    wire [7:0] avg_b = s_b[9:2];

    assign rgb_out = {avg_r[7:3], avg_g[7:2], avg_b[7:3]};

    // 帧同步：长消隐之后的第一个有效像素。
    // vs_flag 在消隐期置起、在 de 重新拉高的那一拍被清掉，
    // 所以 de_in && vs_flag 正好圈住新帧的第一个像素。
    always @(posedge clk) begin
        if(!rstn) frame_sync <= 1'b0;
        else      frame_sync <= de_in && vs_flag;
    end

    // x 为奇数的像素是 2×2 块的右列；y 为奇数的行是块的下行
    always @(posedge clk) begin
        if(!rstn) begin
            de_out <= 1'b0;
            x_out  <= 10'd0;
            y_out  <= 10'd0;
        end
        else begin
            // 对齐：此刻窗口是 (x_d1-1, x_d1)，要用偶数列那一拍才落在 (0,1)
            de_out <= de_d1 && !x_d1[0] && yd1_odd;
            x_out  <= x_d1[10:1];
            y_out  <= y[10:1];
        end
    end

endmodule
