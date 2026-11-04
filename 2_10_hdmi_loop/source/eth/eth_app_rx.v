`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: eth_app_rx
// Description: 应用层协议解析（msg_type = 0x02 检测结果）
//
//   接在 eth_udp_rx 的载荷字节流后面，解析 32 字节应用头 + 16 字节/框。
//
//   头校验：magic = "PNG1"、version = 0x01、msg_type = 0x02
//   框数量：payload_len >> 4（上限 MAXBOX）
//
//   【为什么用暂存区】
//   解析过程中如果发现这一帧不合法，不能把正在显示的框改坏。
//   所以先写进 sx1/sy1/... 暂存，整帧结束且校验通过才一次性提交到输出。
//
//   【输出】
//   update      一帧有效结果到达（单拍）
//   o_nbox      本帧框数量（0 表示"无目标"，上游应清空显示）
//   o_*         打包的框表，用 o_x1[i*16 +: 16] 取第 i 个框
//
//////////////////////////////////////////////////////////////////////////////////

module eth_app_rx #(
    parameter MAXBOX = 32
)(
    input               clk,
    input               rstn,

    // ---- 来自 eth_udp_rx ----
    input               pay_dv,
    input      [7:0]    pay_data,
    input      [15:0]   pay_idx,
    input               frame_end,

    // ---- 结果 ----
    output reg          update,
    output reg [31:0]   o_frame_id,
    output reg [7:0]    o_nbox,
    output reg [MAXBOX*16-1:0] o_x1,
    output reg [MAXBOX*16-1:0] o_y1,
    output reg [MAXBOX*16-1:0] o_x2,
    output reg [MAXBOX*16-1:0] o_y2,
    output reg [MAXBOX*8-1:0]  o_cls,
    output reg [MAXBOX*8-1:0]  o_sub,     // 子类: 交通灯颜色 0=未知 1=红 2=黄 3=绿
    output reg [MAXBOX*8-1:0]  o_conf
);

    //==========================================================================
    //  解析
    //==========================================================================
    reg [7:0]  hdr [0:31];

    reg [15:0] sx1 [0:MAXBOX-1];
    reg [15:0] sy1 [0:MAXBOX-1];
    reg [15:0] sx2 [0:MAXBOX-1];
    reg [15:0] sy2 [0:MAXBOX-1];
    reg [7:0]  scls[0:MAXBOX-1];
    reg [7:0]  ssub[0:MAXBOX-1];
    reg [7:0]  sconf[0:MAXBOX-1];

    wire [15:0] body_i = pay_idx - 16'd32;
    wire [10:0] bi     = body_i[15:4];        // 第几个框
    wire [3:0]  off    = body_i[3:0];         // 框内字节偏移

    wire [15:0] plen   = {hdr[28], hdr[29]};
    wire [15:0] nbox_w = (plen >> 4 > MAXBOX) ? MAXBOX : (plen >> 4);

    wire hdr_ok = (hdr[0] == 8'h50) && (hdr[1] == 8'h4E) &&
                  (hdr[2] == 8'h47) && (hdr[3] == 8'h31) &&
                  (hdr[4] == 8'h01) && (hdr[5] == 8'h02);

    integer i;

    always @(posedge clk) begin
        if(!rstn) begin
            update     <= 1'b0;
            o_frame_id <= 32'd0;
            o_nbox     <= 8'd0;
            o_x1       <= {(MAXBOX*16){1'b0}};
            o_y1       <= {(MAXBOX*16){1'b0}};
            o_x2       <= {(MAXBOX*16){1'b0}};
            o_y2       <= {(MAXBOX*16){1'b0}};
            o_cls      <= {(MAXBOX*8){1'b0}};
            o_sub      <= {(MAXBOX*8){1'b0}};
            o_conf     <= {(MAXBOX*8){1'b0}};
        end
        else begin
            update <= 1'b0;

            //---- 收字节 ----
            if(pay_dv) begin
                if(pay_idx < 16'd32) begin
                    hdr[pay_idx[4:0]] <= pay_data;
                end
                else if(bi < MAXBOX) begin
                    case(off)
                        4'd0 : sx1[bi[4:0]][15:8] <= pay_data;
                        4'd1 : sx1[bi[4:0]][7:0]  <= pay_data;
                        4'd2 : sy1[bi[4:0]][15:8] <= pay_data;
                        4'd3 : sy1[bi[4:0]][7:0]  <= pay_data;
                        4'd4 : sx2[bi[4:0]][15:8] <= pay_data;
                        4'd5 : sx2[bi[4:0]][7:0]  <= pay_data;
                        4'd6 : sy2[bi[4:0]][15:8] <= pay_data;
                        4'd7 : sy2[bi[4:0]][7:0]  <= pay_data;
                        4'd8 : scls[bi[4:0]]      <= pay_data;
                        4'd9 : ssub[bi[4:0]]      <= pay_data;   // 红绿灯颜色
                        4'd10: sconf[bi[4:0]]     <= pay_data;
                        default: ;
                    endcase
                end
            end

            //---- 帧结束，校验通过则提交 ----
            if(frame_end && hdr_ok) begin
                update     <= 1'b1;
                o_frame_id <= {hdr[8], hdr[9], hdr[10], hdr[11]};
                o_nbox     <= nbox_w[7:0];
                for(i = 0; i < MAXBOX; i = i + 1) begin
                    o_x1[i*16 +: 16] <= sx1[i];
                    o_y1[i*16 +: 16] <= sy1[i];
                    o_x2[i*16 +: 16] <= sx2[i];
                    o_y2[i*16 +: 16] <= sy2[i];
                    o_cls[i*8  +: 8 ] <= scls[i];
                    o_sub[i*8  +: 8 ] <= ssub[i];
                    o_conf[i*8 +: 8 ] <= sconf[i];
                end
            end
        end
    end

endmodule
