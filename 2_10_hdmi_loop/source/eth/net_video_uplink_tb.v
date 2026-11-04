`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// net_video_uplink 乒乓缓冲自检
//
//   用小尺寸帧（源 32×16 → 上传 16×8）跑十几帧，验证三件事：
//
//   1. 安全不变量：采集永远不写正在发送的 bank
//        assert !(cap_en && busy && wr_bank == rd_bank)
//      违反的表现是画面撕裂 —— 这是这次改动最主要的风险。
//
//   2. 每帧数据完整：给每一帧一个固定的纯色，发送期间读到的
//      半个字节流（高低字节分开看）必须始终等于同一常数。
//      一旦读到两个不同 bank 的数据，就会看到两个不同常数混在一起。
//
//   3. 连续两帧的颜色不同：证明发出去的是新帧，不是卡住的旧帧。
//
//   编译: iverilog -g2012 -o uplink_tb net_video_uplink_tb.v net_video_uplink.v \
//                        eth_udp_video_tx.v eth_udp_tx.v eth_frame_tx.v video_downsample.v
//   运行: vvp uplink_tb
//////////////////////////////////////////////////////////////////////////////////

module net_video_uplink_tb;

    // 源帧 32×16，上传 16×8
    localparam SRC_W = 32;
    localparam SRC_H = 16;
    localparam IMG_W = 16;
    localparam IMG_H = 8;
    localparam NPIX  = IMG_W * IMG_H;          // 128

    localparam HT  = 40;                        // 行总长
    localparam VT  = 160;                       // 场总长（垂直消隐 144 行 = 5760 拍 > GAP_THRESH 5000）
    localparam GAP = 8000;                      // 包间隔，故意让发送慢于采集，逼出乒乓等待路径

    //------------------------------------------------------------------
    //  时钟与复位
    //------------------------------------------------------------------
    reg pix_clk = 0;
    reg net_clk = 0;
    always #5  pix_clk = ~pix_clk;             // 10 ns
    always #4  net_clk = ~net_clk;             //  8 ns

    // 像素域早早起来，网络域故意晚 5 帧才出复位 —— 复现真实上电时序：
    // PHY 要重新协商 + PLL 要锁定，网络域比像素域晚好几秒。
    // 没有 net_alive 握手的话，这个场景会死锁（实测：网口一包都没有）。
    reg rstn     = 0;
    reg net_rstn = 0;

    //------------------------------------------------------------------
    //  视频源：每帧一个纯色
    //------------------------------------------------------------------
    reg        de = 0;
    reg [7:0]  r = 0, g = 0, b = 0;
    reg [10:0] vx = 0, vy = 0;
    reg [7:0]  frame_color = 0;                 // 当前帧的灰度值

    wire tx_en;
    wire [7:0] txd;
    wire [31:0] frame_cnt;
    wire link_busy;

    always @(negedge pix_clk) begin
        if(!rstn) begin
            vx <= 0; vy <= 0; de <= 0;
        end
        else begin
            if(vx == HT-1) begin
                vx <= 0;
                if(vy == VT-1) begin
                    vy <= 0;
                    frame_color <= frame_color + 8'd16;    // 每帧换一个颜色
                end
                else vy <= vy + 1;
            end
            else vx <= vx + 1;

            de <= (vx < SRC_W) && (vy < SRC_H);
            r  <= frame_color;
            g  <= frame_color;
            b  <= frame_color;
        end
    end

    net_video_uplink #(
        .IMG_W    ( IMG_W ),
        .IMG_H    ( IMG_H ),
        .SRC_W    ( SRC_W ),
        .SRC_H    ( SRC_H ),
        .DATA_PER ( NPIX  ),        // 一帧一包，便于观察
        .PKT_GAP  ( GAP   ),
        .FRAME_IFG ( GAP  )
    ) dut (
        .pix_clk   ( pix_clk ),
        .pix_rstn  ( rstn    ),
        .de_in     ( de      ),
        .r_in      ( r       ),
        .g_in      ( g       ),
        .b_in      ( b       ),
        .net_clk   ( net_clk ),
        .net_rstn  ( net_rstn ),
        .tx_en     ( tx_en   ),
        .txd       ( txd     ),
        .frame_cnt ( frame_cnt ),
        .link_busy ( link_busy )
    );

    //------------------------------------------------------------------
    //  检查逻辑
    //------------------------------------------------------------------
    // fb_data 比 fb_addr 晚 2 拍：BRAM 输出寄存 + bank 选择寄存
    reg [18:0] fb_addr_d1, fb_addr_d2;
    always @(posedge net_clk) begin
        fb_addr_d1 <= dut.fb_addr;
        fb_addr_d2 <= fb_addr_d1;
    end
    wire [18:0] fb_addr_d = fb_addr_d2;

    reg [7:0] hi_min, hi_max, lo_min, lo_max;
    reg [7:0] prev_hi = 8'hFF, prev_lo = 8'hFF;
    reg       have_prev = 0;

    // 网络域复位时把统计清零，避免把复位前后两帧误判成"重复/不纯"
    always @(negedge net_rstn) begin
        have_prev <= 1'b0;
        hi_min <= 8'hFF; hi_max <= 8'h00;
        lo_min <= 8'hFF; lo_max <= 8'h00;
        nsamp  <= 0;
    end

    integer sent = 0;
    integer bad_uniform = 0;
    integer bad_dup = 0;
    integer violations = 0;

    time t_last_done = 0;
    time t_first_done = 0;
    time period_sum = 0;

    initial begin
        hi_min = 8'hFF; hi_max = 8'h00;
        lo_min = 8'hFF; lo_max = 8'h00;
    end

    // 不变量 1：采集不能写正在发送的 bank
    always @(posedge pix_clk) begin
        if(rstn && dut.cap_en && link_busy && (dut.wr_bank == dut.rd_bank)) begin
            violations = violations + 1;
            if(violations <= 3)
                $display("  !! 违例 t=%0t  cap_en=1 busy=1 wr_bank=rd_bank=%0d",
                         $time, dut.wr_bank);
        end
    end

    // 每次发送开头几拍 fb_data 还是上一帧的残留（BRAM 读延迟），跳过
    reg     busy_r = 0;
    integer settle = 0;
    always @(posedge net_clk) begin
        busy_r <= dut.u_video.busy;
        if(dut.u_video.busy && !busy_r) begin
            settle       <= 3;
            rd_bank_used <= dut.rd_bank;
        end
        else if(settle != 0)             settle <= settle - 1;
    end

    integer nsamp = 0;

    // ---- 调试：每个 bank 写了多少拍、读到多少 X ----
    integer wr_cnt0 = 0, wr_cnt1 = 0, xcnt = 0;
    reg     rd_bank_used = 0;
    always @(posedge pix_clk)
        if(dut.cap_en && dut.ds_de) begin
            if(dut.wr_bank) wr_cnt1 = wr_cnt1 + 1;
            else            wr_cnt0 = wr_cnt0 + 1;
        end
    always @(posedge net_clk)
        if(dut.u_video.busy && (dut.fb_data === 8'hxx)) xcnt = xcnt + 1;

    // 不变量 2/3：发送期间读到的数据必须来自同一帧
    always @(posedge net_clk) begin
        if(net_rstn && dut.u_video.busy && settle == 0) begin
            nsamp = nsamp + 1;
            if(!fb_addr_d[0]) begin
                if(dut.fb_data < hi_min) hi_min <= dut.fb_data;
                if(dut.fb_data > hi_max) hi_max <= dut.fb_data;
            end
            else begin
                if(dut.fb_data < lo_min) lo_min <= dut.fb_data;
                if(dut.fb_data > lo_max) lo_max <= dut.fb_data;
            end
        end

        if(net_rstn && dut.u_video.frame_done) begin
            sent = sent + 1;
            if(sent <= 12)
                $display("  帧 %0d: 采样 %0d 拍, 读bank=%0d, hi %0d..%0d lo %0d..%0d",
                         sent, nsamp, rd_bank_used, hi_min, hi_max, lo_min, lo_max);
            nsamp = 0;
            if(hi_min != hi_max || lo_min != lo_max) begin
                bad_uniform = bad_uniform + 1;
                if(bad_uniform <= 5)
                    $display("  !! 帧 %0d 数据不纯: hi %0d..%0d  lo %0d..%0d",
                             sent, hi_min, hi_max, lo_min, lo_max);
            end
            if(have_prev && (hi_max == prev_hi) && (lo_max == prev_lo)) begin
                bad_dup = bad_dup + 1;
                if(bad_dup <= 5)
                    $display("  !! 帧 %0d 和上一帧完全相同 (hi=%0d lo=%0d)",
                             sent, hi_max, lo_max);
            end
            prev_hi  = hi_max;
            prev_lo  = lo_max;
            have_prev = 1'b1;

            if(sent == 1) t_first_done = $time;
            else          period_sum = period_sum + ($time - t_last_done);
            t_last_done = $time;

            hi_min <= 8'hFF; hi_max <= 8'h00;
            lo_min <= 8'hFF; lo_max <= 8'h00;
        end
    end

    //------------------------------------------------------------------
    initial begin
        #100 rstn = 1;
        repeat (5 * HT * VT) @(negedge pix_clk);   // 像素域先跑 5 帧
        net_rstn = 1;                              // 网络域此时才出复位

        repeat (5 * HT * VT) @(negedge pix_clk);
        // 模拟 PHY 上电时 PLL 抖动：网络域复位一下再放出来
        $display("  -- 网络域复位一次（模拟 PLL 抖动）--");
        net_rstn = 0;
        repeat (2 * HT * VT) @(negedge pix_clk);
        net_rstn = 1;

        // 之后跑 12 帧
        repeat (12 * HT * VT) @(negedge pix_clk);
        repeat (20000) @(negedge net_clk);

        $display("");
        $display("  发送帧数      : %0d", sent);
        $display("  采集帧数信号  : frame_cnt=%0d", frame_cnt);
        if(sent > 1 && period_sum > 0)
            $display("  平均发送间隔  : %0.0f ns  (= %0.2f fps)",
                     period_sum * 1.0 / (sent - 1),
                     1.0e9 / (period_sum * 1.0 / (sent - 1)));
        $display("  写入 bank0/bank1    : %0d / %0d", wr_cnt0, wr_cnt1);
        $display("  读到 X 的拍数       : %0d", xcnt);
        $display("  采集/发送 bank 冲突 : %0d", violations);
        $display("  帧内数据不纯        : %0d", bad_uniform);
        $display("  重复旧帧            : %0d", bad_dup);

        if(sent >= 8 && violations == 0 && bad_uniform == 0 && bad_dup == 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $finish;
    end

endmodule
