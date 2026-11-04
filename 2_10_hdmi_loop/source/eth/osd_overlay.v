`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: osd_overlay
// Description: 在视频流上画检测框（只画边框）和分类序号
//
//   逐像素判断是否落在某个框的边缘上，是就用框的颜色替换原像素；
//   另外在框的左上角上方画一位分类序号（0=车 1=人 2=红绿灯 3=骑行）。
//
//   纯组合，不引入额外延迟，所以框坐标和画面严格对齐。
//
//   坐标系统：原始帧 1280×720。PC 回传的框就是按这个坐标系算的，
//   这里直接比较，不做任何缩放。
//
//   行号靠 de 下降沿累加、长消隐判帧边界（MS7200 不输出 vs）。
//
//   序号是 8×8 点阵 × LBL_SCL 倍放大，黑底 + 类别色字，画在
//   (bx1, by1-17) 起的 LBL_W×LBL_H 区域。by1 < 17 时减法下溢，
//   比较恒不成立，序号自然不画 —— 不会跑出屏幕。
//////////////////////////////////////////////////////////////////////////////////

module osd_overlay #(
    parameter NBOX     = 32,
    parameter H_ACT    = 1280,
    parameter V_ACT    = 720,
    parameter THICK    = 2,         // 边框粗细（像素）
    parameter GAP_THR  = 5000,      // de 连续低这么多拍判定为帧间隔
    parameter LABEL_EN = 1,         // 画分类序号
    parameter LBL_SCL  = 2          // 点阵放大倍数（1=8px，2=16px）
)(
    input                     pix_clk,
    input                     rstn,

    input                     de_in,
    input      [7:0]          r_in,
    input      [7:0]          g_in,
    input      [7:0]          b_in,

    input                     enable,
    input      [7:0]          nbox,
    input      [NBOX*16-1:0]  bx1,
    input      [NBOX*16-1:0]  by1,
    input      [NBOX*16-1:0]  bx2,
    input      [NBOX*16-1:0]  by2,
    input      [NBOX*8-1:0]   bcls,
    input      [NBOX*8-1:0]   bsub,     // 子类: 交通灯颜色 0=未知 1=红 2=黄 3=绿

    // 输出保持组合。寄存放到顶层 hdmi_loop.v 里，和 HS/VS 一起用一个
    // always 块寄存 —— 保证六个信号严格对齐（否则画面左右抖动），
    // 同时让寄存器带内部扇出，不会被综合吸进 I/O 单元（吸进去框就丢了）。
    output                    de_out,
    output      [7:0]         r_out,
    output      [7:0]         g_out,
    output      [7:0]         b_out
);

    localparam [15:0] LBL_W  = 8 * LBL_SCL;    // 序号区域宽
    localparam [15:0] LBL_H  = 8 * LBL_SCL;    // 序号区域高
    localparam [15:0] LBL_UP = 17;             // 框上方 1 像素间隔

    //==========================================================================
    //  像素坐标
    //==========================================================================
    reg [11:0] x, y;
    reg        de_d;
    reg [14:0] gap;

    wire line_end = de_d && !de_in;

    always @(posedge pix_clk) begin
        if(!rstn) begin
            x    <= 12'd0;
            y    <= 12'd0;
            de_d <= 1'b0;
            gap  <= 15'd0;
        end
        else begin
            de_d <= de_in;

            if(de_in) x <= x + 12'd1;
            else      x <= 12'd0;

            if(line_end) y <= y + 12'd1;

            if(!de_in) begin
                if(gap != 15'h7FFF) gap <= gap + 15'd1;
                if(gap >= GAP_THR)  y   <= 12'd0;
            end
            else gap <= 15'd0;
        end
    end

    //==========================================================================
    //  数字字模 8×8，高位在左，每行一个字节（row0 = 最高字节）
    //==========================================================================
    function [63:0] font_digit;
        input [3:0] d;
        begin
            case(d)
                4'd0: font_digit = 64'h3C_66_66_66_66_66_3C_00;
                4'd1: font_digit = 64'h18_38_18_18_18_18_7E_00;
                4'd2: font_digit = 64'h3C_66_06_0C_30_60_7E_00;
                4'd3: font_digit = 64'h3C_66_06_1C_06_66_3C_00;
                4'd4: font_digit = 64'h0C_1C_3C_6C_7E_0C_0C_00;
                4'd5: font_digit = 64'h7E_60_7C_06_06_66_3C_00;
                4'd6: font_digit = 64'h1C_30_60_7C_66_66_3C_00;
                4'd7: font_digit = 64'h7E_06_0C_18_30_30_30_00;
                4'd8: font_digit = 64'h3C_66_66_3C_66_66_3C_00;
                4'd9: font_digit = 64'h3C_66_66_3E_06_0C_38_00;
                default: font_digit = 64'h00_00_00_00_00_00_00_00;
            endcase
        end
    endfunction

    //==========================================================================
    //  框表双缓冲：只在帧消隐期整体更新
    //
    //  【为什么必须这样】框表是收到 PC 结果时立刻更新的，每秒约 20 次，
    //  和 60Hz 的视频帧完全异步。更新正好落在扫描到一半时，上半屏按旧框画、
    //  下半屏按新框画 —— 一个框的上边来自旧检测、下边来自新检测，看上去
    //  就是"一条边突然跑出去很远"，下一帧又恢复。
    //  实测坐标数据本身干净（最大框 468×416、越界 0、反向 0），所以问题
    //  不在数据，在绘制时机。
    //
    //  消隐期把整张表锁存，画的过程中绝不改变；代价是最多晚一帧生效（16.7ms）。
    //==========================================================================
    reg [7:0]         dnbox;
    reg [NBOX*16-1:0] dbx1, dby1, dbx2, dby2;
    reg [NBOX*8-1:0]  dbcls, dbsub;

    wire frame_begin = (!de_in) && (gap >= GAP_THR);   // 消隐期 = 新一帧开始

    always @(posedge pix_clk) begin
        if(!rstn) begin
            dnbox <= 8'd0;
            dbx1  <= {(NBOX*16){1'b0}};
            dby1  <= {(NBOX*16){1'b0}};
            dbx2  <= {(NBOX*16){1'b0}};
            dby2  <= {(NBOX*16){1'b0}};
            dbcls <= {(NBOX*8){1'b0}};
            dbsub <= {(NBOX*8){1'b0}};
        end
        else if(frame_begin) begin
            dnbox <= nbox;
            dbx1  <= bx1;
            dby1  <= by1;
            dbx2  <= bx2;
            dby2  <= by2;
            dbcls <= bcls;
            dbsub <= bsub;
        end
    end

    //==========================================================================
    //  逐框比较：边框 + 序号区域
    //==========================================================================
    integer i;
    reg        hit;
    reg [7:0]  hr, hg, hb;

    reg        l_hit;
    reg [3:0]  l_cls;
    reg [2:0]  l_col;
    reg [2:0]  l_row;
    reg [7:0]  l_fg_r, l_fg_g, l_fg_b;

    always @(*) begin
        hit = 1'b0;
        hr  = 8'd0;
        hg  = 8'd255;
        hb  = 8'd0;

        l_hit  = 1'b0;
        l_cls  = 4'd0;
        l_col  = 3'd0;
        l_row  = 3'd0;
        l_fg_r = 8'd0;
        l_fg_g = 8'd255;
        l_fg_b = 8'd0;

        for(i = 0; i < NBOX; i = i + 1) begin
            if(i < dnbox) begin
                // ---------------- 边框 ----------------
                if( (x >= dbx1[i*16 +: 16]) && (x <= dbx2[i*16 +: 16]) &&
                    (y >= dby1[i*16 +: 16]) && (y <= dby2[i*16 +: 16]) ) begin
                    // 只在边框上画
                    if( (x < dbx1[i*16 +: 16] + THICK) ||
                        (x + THICK > dbx2[i*16 +: 16])     ||
                        (y < dby1[i*16 +: 16] + THICK) ||
                        (y + THICK > dby2[i*16 +: 16]) ) begin
                        hit = 1'b1;
                        case(dbcls[i*8 +: 8])
                            8'd0   : begin hr = 8'd0;   hg = 8'd255; hb = 8'd0;   end // 车: 绿
                            8'd1   : begin hr = 8'd255; hg = 8'd255; hb = 8'd0;   end // 人: 黄
                            8'd2   : begin                                          // 交通灯: 按灯色
                                case(dbsub[i*8 +: 8])
                                    8'd1   : begin hr = 8'd255; hg = 8'd0;   hb = 8'd0;   end // 红
                                    8'd2   : begin hr = 8'd255; hg = 8'd255; hb = 8'd0;   end // 黄
                                    8'd3   : begin hr = 8'd0;   hg = 8'd255; hb = 8'd0;   end // 绿
                                    default: begin hr = 8'd128; hg = 8'd128; hb = 8'd128; end // 未知: 灰
                                endcase
                            end
                            default: begin hr = 8'd255; hg = 8'd255; hb = 8'd255; end
                        endcase
                    end
                end

                // ---------------- 分类序号 ----------------
                // 画在框左上角上方；by1 < LBL_UP 时下溢，条件恒假，不画
                if( LABEL_EN &&
                    (x >= dbx1[i*16 +: 16]) &&
                    (x <  dbx1[i*16 +: 16] + LBL_W) &&
                    (y >= dby1[i*16 +: 16] - LBL_UP) &&
                    (y <  dby1[i*16 +: 16] - LBL_UP + LBL_H) ) begin
                    l_hit  = 1'b1;
                    l_cls  = dbcls[i*8 +: 4];
                    l_col  = (x - dbx1[i*16 +: 16]) >> 1;
                    l_row  = (y - (dby1[i*16 +: 16] - LBL_UP)) >> 1;
                    case(dbcls[i*8 +: 8])
                        8'd0   : begin l_fg_r = 8'd0;   l_fg_g = 8'd255; l_fg_b = 8'd0;   end
                        8'd1   : begin l_fg_r = 8'd255; l_fg_g = 8'd255; l_fg_b = 8'd0;   end
                        8'd2   : begin
                            case(dbsub[i*8 +: 8])
                                8'd1   : begin l_fg_r = 8'd255; l_fg_g = 8'd0;   l_fg_b = 8'd0;   end
                                8'd2   : begin l_fg_r = 8'd255; l_fg_g = 8'd255; l_fg_b = 8'd0;   end
                                8'd3   : begin l_fg_r = 8'd0;   l_fg_g = 8'd255; l_fg_b = 8'd0;   end
                                default: begin l_fg_r = 8'd128; l_fg_g = 8'd128; l_fg_b = 8'd128; end
                            endcase
                        end
                        default: begin l_fg_r = 8'd255; l_fg_g = 8'd255; l_fg_b = 8'd255; end
                    endcase
                end
            end
        end
    end

    //==========================================================================
    //  字模查表（整个模块只做一份，不进 32 次循环）
    //==========================================================================
    wire [63:0] l_glyph = font_digit(l_cls);
    wire [2:0]  l_inv   = 3'd7 - l_row;          // row0 在最高字节
    wire [5:0]  l_base  = {l_inv, 3'b000};
    wire [7:0]  l_byte  = l_glyph[l_base +: 8];
    wire        l_px    = l_byte[3'd7 - l_col];  // 高位在左

    //==========================================================================
    //  输出（组合，寄存由顶层统一做）
    //  序号优先于边框：序号区域在框外面，正常不会重叠
    //==========================================================================
    assign de_out = de_in;
    assign r_out  = (de_in && enable && l_hit) ? (l_px ? l_fg_r : 8'd0) :
                    (de_in && enable && hit)   ? hr : r_in;
    assign g_out  = (de_in && enable && l_hit) ? (l_px ? l_fg_g : 8'd0) :
                    (de_in && enable && hit)   ? hg : g_in;
    assign b_out  = (de_in && enable && l_hit) ? (l_px ? l_fg_b : 8'd0) :
                    (de_in && enable && hit)   ? hb : b_in;

endmodule
