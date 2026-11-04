`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:  Ziguang Tongchuang Competition
// Engineer:
//
// Create Date: 2026-10-16
// Module Name: video_timing
// Description: 视频时序测量
//
//   从 de/hs/vs 里量出当前输入的实际分辨率和帧率, 供后续模块和 MCU 使用。
//
//   【为什么不全靠 vs】
//   有些 HDMI 接收芯片(比如这里的 MS7200)在默认配置下不输出 vs —— 下游的
//   MS7210 用 DE 自己就能重建时序。所以场边界改成用「DE 的间隙」检测:
//   连续多行没有 DE 就是进入了场消隐, 消隐之后第一个有 DE 的行就是新的一帧。
//   这样 vs 有没有都无所谓。vs 只作为辅助(任意边沿也计一次), 用于兼容。
//
//   【测量方法】
//     H_ACT: 每行统计 de 为高的像素数
//     V_ACT: 每场统计 de 为高的行数
//     连续 2 次结果一致才发布, 避免切分辨率瞬间的中间值被下游误用
//
//   【诊断输出 dbg_line_cnt】
//     每个"行结束"加一, 自由运行。MCU 读它就能判断 de 到底有没有在动:
//     持续增长 -> de 正常; 一直不变 -> de 没进来。
//
//////////////////////////////////////////////////////////////////////////////////

module video_timing (
    input               pix_clk,
    input               rstn,

    input               de,
    input               vs,

    output reg [11:0]   h_act,       // 每行有效像素数
    output reg [11:0]   v_act,       // 每场有效行数
    output reg [15:0]   frame_cnt,   // 场计数器
    output reg          stable,      // 测量结果已稳定

    output reg [15:0]   dbg_line_cnt // 诊断: 行结束计数, 自由运行
);

    localparam STABLE_LINES = 3;     // 连续多少次一致才认为稳定
    localparam BLANK_LINES  = 3;     // 连续多少行没有 de 认为进入场消隐

    //==========================================================================
    //  1. 行像素计数
    //==========================================================================
    reg  [11:0] h_cnt;
    reg         de_d;
    always @(posedge pix_clk) begin
        if(!rstn) begin
            h_cnt <= 12'd0;
            de_d  <= 1'b0;
        end
        else begin
            de_d <= de;
            if(!de) h_cnt <= 12'd0;
            else    h_cnt <= h_cnt + 1'b1;
        end
    end

    wire line_end = ~de & de_d;      // de 下降沿 = 一行结束

    // 诊断计数
    always @(posedge pix_clk) begin
        if(!rstn)               dbg_line_cnt <= 16'd0;
        else if(line_end)       dbg_line_cnt <= dbg_line_cnt + 1'b1;
    end

    //==========================================================================
    //  2. 行像素数发布 (连续 2 行一致)
    //==========================================================================
    reg  [11:0] h_last;
    always @(posedge pix_clk) begin
        if(!rstn) begin
            h_last <= 12'd0;
            h_act  <= 12'd0;
        end
        else if(line_end) begin
            if((h_cnt != 12'd0) && (h_cnt == h_last))
                h_act <= h_cnt;
            h_last <= h_cnt;
        end
    end

    //==========================================================================
    //  3. 场边界检测 (用 DE 间隙, 不依赖 vs)
    //==========================================================================
    reg  [3:0] blank_run;            // 连续多少个"空行"
    reg        in_vblank;
    reg        vs_d;

    always @(posedge pix_clk) begin
        vs_d <= vs;
    end
    wire vs_edge = vs ^ vs_d;        // vs 若有信号, 也认它

    always @(posedge pix_clk) begin
        if(!rstn) begin
            blank_run <= 4'd0;
            in_vblank <= 1'b1;
        end
        else if(line_end) begin
            if(h_cnt == 12'd0) begin
                // 这一行一个有效像素都没有 -> 空行
                if(blank_run != 4'd15) blank_run <= blank_run + 1'b1;
                if(blank_run >= (BLANK_LINES - 1)) in_vblank <= 1'b1;
            end
            else begin
                blank_run <= 4'd0;
                in_vblank <= 1'b0;
            end
        end
    end

    // 新一帧的第一行: 消隐之后第一个有 DE 的行; 或者 vs 的任意边沿
    wire frame_edge = (line_end && (h_cnt != 12'd0) && in_vblank) || vs_edge;

    //==========================================================================
    //  4. 场行计数
    //==========================================================================
    reg  [11:0] v_cnt;
    always @(posedge pix_clk) begin
        if(!rstn)               v_cnt <= 12'd0;
        else if(frame_edge)     v_cnt <= 12'd0;
        else if(line_end)       v_cnt <= v_cnt + 1'b1;
    end

    reg  [11:0] v_last;
    always @(posedge pix_clk) begin
        if(!rstn) begin
            v_last <= 12'd0;
            v_act  <= 12'd0;
        end
        else if(frame_edge) begin
            if(v_cnt != 12'd0) begin
                if(v_cnt == v_last) v_act <= v_cnt;
                v_last <= v_cnt;
            end
        end
    end

    //==========================================================================
    //  5. 场计数 + 稳定标志
    //==========================================================================
    reg [3:0] h_ok;
    always @(posedge pix_clk) begin
        if(!rstn) begin
            h_ok <= 4'd0;
        end
        else if(line_end) begin
            if(h_cnt == h_last && h_cnt != 12'd0) begin
                if(h_ok != 4'd15) h_ok <= h_ok + 1'b1;
            end
            else h_ok <= 4'd0;
        end
    end

    always @(posedge pix_clk) begin
        if(!rstn) stable <= 1'b0;
        else      stable <= (h_ok >= STABLE_LINES) && (h_act != 12'd0) && (v_act != 12'd0);
    end

    always @(posedge pix_clk) begin
        if(!rstn)               frame_cnt <= 16'd0;
        else if(frame_edge)     frame_cnt <= frame_cnt + 1'b1;
    end

endmodule
