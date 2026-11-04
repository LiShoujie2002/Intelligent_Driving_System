`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:Meyesemi 
// Engineer: bill
// 
// Create Date: 2024-06-17 16:05  
// Design Name:  
// Module Name: 
// Project Name: 
// Target Devices: Pango
// Tool Versions: 
// Description: 
//      
// Dependencies: 
// 
// Revision:
// Revision 1.0 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////
`define UD #1

module hdmi_loop(
    input wire        sys_clk       ,// input system clock 50MHz    
    output            rstn_out      ,
    output            hd_scl    ,
    inout             hd_sda    ,
    output            led_int       ,
//hdmi_out
    output              pixclk_out       ,//pixclk
    output               vs_out        ,
    output               hs_out        ,
    output               de_out        ,
    output     [7:0]     r_out         ,
    output     [7:0]     g_out         ,
    output     [7:0]     b_out         ,

//HDMI_IN
    input             pixclk_in     ,                            
    input             vs_in         , 
    input             hs_in         , 
    input             de_in         ,
    input     [7:0]   r_in          , 
    input     [7:0]   g_in          , 
    input     [7:0]   b_in          ,

//串口 (板载 CP2102: RXD=B24, TXD=C24)
    input               uart_rxd    ,
    output              uart_txd    ,

// RGMII 千兆网口 (RTL8211F-CG)
    input               rgmii_rxc   ,
    input               rgmii_rx_ctl,
    input      [3:0]    rgmii_rxd   ,
    output              rgmii_txc   ,
    output              rgmii_tx_ctl,
    output     [3:0]    rgmii_txd
    // 注意: PHY 复位用的是已有的 rstn_out (G25)，配置后 1ms 拉高，
    // 不依赖网口时钟，因此不会出现 "复位->PHY没时钟->PLL锁不上" 的死锁。
);

parameter   X_WIDTH = 4'd12;
parameter   Y_WIDTH = 4'd12;    

//MODE_1080p
    parameter V_TOTAL = 12'd1125;
    parameter V_FP = 12'd4;
    parameter V_BP = 12'd36;
    parameter V_SYNC = 12'd5;
    parameter V_ACT = 12'd1080;
    parameter H_TOTAL = 12'd2200;
    parameter H_FP = 12'd88;
    parameter H_BP = 12'd148;
    parameter H_SYNC = 12'd44;
    parameter H_ACT = 12'd1920;
    parameter HV_OFFSET = 12'd0;

    wire                        pix_clk    ;
    wire                        cfg_clk    ;
    wire                        locked     ;
    wire                        rstn       ;
    wire                        init_over  ;
    reg  [15:0]                 rstn_1ms   ;
    wire [X_WIDTH - 1'b1:0]     act_x      ;
    wire [Y_WIDTH - 1'b1:0]     act_y      ;    
    wire                        hs         ;
    wire                        vs         ;
    wire                        de         ;
    reg  [3:0]                  reset_delay_cnt;



PLL u_pll (
  .clkout0(cfg_clk),    // output
  .lock(locked),          // output
  .clkin1(sys_clk)       // input
);


ms72xx_ctl ms72xx_ctl(
    .clk         (  cfg_clk    ), //input       clk,
    .rst_n       (  rstn_out   ), //input       rstn,
           
    .init_over_rx(  rx_init_done),                 
    .init_over   (  init_over  ), //output      init_over,
    .iic_scl     (  hd_scl    ), //output      iic_scl,
    .iic_sda     (  hd_sda    )  //inout       iic_sda
);
assign    led_int    =     led_dbg[0];   // 心跳灯: 由软核驱动, 见 main.c

always @(posedge cfg_clk)
begin
	if(!locked)
	    rstn_1ms <= 16'd0;
	else
	begin
		if(rstn_1ms == 16'h2710)
		    rstn_1ms <= rstn_1ms;
		else
		    rstn_1ms <= rstn_1ms + 1'b1;
	end
end

assign rstn_out = (rstn_1ms == 16'h2710);
assign rx_rst_n = rstn_out;
/*
    sync_vg #(
        .X_BITS               (  X_WIDTH              ), 
        .Y_BITS               (  Y_WIDTH              ),
        .V_TOTAL              (  V_TOTAL              ),//                        
        .V_FP                 (  V_FP                 ),//                        
        .V_BP                 (  V_BP                 ),//                        
        .V_SYNC               (  V_SYNC               ),//                        
        .V_ACT                (  V_ACT                ),//                        
        .H_TOTAL              (  H_TOTAL              ),//                        
        .H_FP                 (  H_FP                 ),//                        
        .H_BP                 (  H_BP                 ),//                        
        .H_SYNC               (  H_SYNC               ),//                        
        .H_ACT                (  H_ACT                ) //                        
 
    ) sync_vg                                         
    (                                                 
        .clk                  (  pix_clk               ),//input                   clk,                                 
        .rstn                 (  rstn_out                 ),//input                   rstn,                            
        .vs_out               (  vs                   ),//output reg              vs_out,                                                                                                                                      
        .hs_out               (  hs                   ),//output reg              hs_out,            
        .de_out               (  de                   ),//output reg              de_out,             
        .x_act                (  act_x                ),//output reg [X_BITS-1:0] x_out,             
        .y_act                (  act_y                ) //output reg [Y_BITS:0]   y_out,             
    );
    
    pattern_vg #(
        .COCLOR_DEPP          (  8                    ), // Bits per channel
        .X_BITS               (  X_WIDTH              ),
        .Y_BITS               (  Y_WIDTH              ),
        .H_ACT                (  H_ACT                ),
        .V_ACT                (  V_ACT                )
    ) // Number of fractional bits for ramp pattern
    pattern_vg (
        .rstn                 (  rstn_out                 ),//input                         rstn,                                                     
        .pix_clk              (  pix_clk               ),//input                         clk_in,  
        .act_x                (  act_x                ),//input      [X_BITS-1:0]       x,   
        // input video timing
        .vs_in                (  vs                   ),//input                         vn_in                        
        .hs_in                (  hs                   ),//input                         hn_in,                           
        .de_in                (  de                   ),//input                         dn_in,
        // test pattern image output                                                    
        .vs_out               (  vs_out               ),//output reg                    vn_out,                       
        .hs_out               (  hs_out               ),//output reg                    hn_out,                       
        .de_out               (  de_out               ),//output reg                    den_out,                      
        .r_out                (  r_out                ),//output reg [COCLOR_DEPP-1:0]  r_out,                      
        .g_out                (  g_out                ),//output reg [COCLOR_DEPP-1:0]  g_out,                       
        .b_out                (  b_out                ) //output reg [COCLOR_DEPP-1:0]  b_out   
    );
*/

//HDMI_OUT  =  经视频处理后的 HDMI_IN
    assign pixclk_out   =  pixclk_in    ;

    //--------------------------------------------------------------------------
    //  init_over 跨时钟域同步
    //  init_over 由 10MHz 的 cfg_clk 域产生。原实现把它直接当成像素路径的
    //  异步置位, 在 148.5MHz 下是一条真实的 CDC 违例(恢复时间 slack -3.4ns),
    //  且会给输出寄存器引入 -3.6ns 的建立违例。这里打两拍同步到像素域,
    //  只当普通输出使能使用。
    //--------------------------------------------------------------------------
    reg     init_over_meta;
    reg     init_over_sync;

    always @(posedge pixclk_out) begin
        init_over_meta <= init_over;
        init_over_sync <= init_over_meta;
    end

    //--------------------------------------------------------------------------
    //  输入寄存 (关键!)
    //  必须给综合器一个"可以放进输入 IOB"的寄存器。否则它会把这条路径上的
    //  寄存器全部合并到输出 IOB, 使 "输入焊盘 -> 输出寄存器" 退化成一段超长
    //  组合路径: 实测布线 2.526ns + IBUF 1.007ns = 3.558ns, 而像素时钟插入
    //  延迟只有 3.228ns, 保持余量仅剩 0.33ns。
    //
    //  DE/HS/VS 也走这条路径 —— 它们一旦抖动, MS7210 拿到的同步信号就是错的,
    //  显示器反复失锁重锁, 表现就是"频闪、无法持续点亮"。
    //
    //  加了这一拍之后, 输入焊盘 -> 输入IOB寄存器 成为短路径, 后续长布线获得
    //  完整一个时钟周期, fdc 里输入端口上的 PAP_IO_REGISTER 也才真正生效。
    //--------------------------------------------------------------------------
    wire [26:0] vid_in   = { r_in, g_in, b_in, de_in, hs_in, vs_in };
    reg  [26:0] vid_in_r;

    always @(posedge pixclk_out) begin
        vid_in_r <= vid_in;
    end

    //--------------------------------------------------------------------------
    //  视频处理流水线: 灰度化 -> 3x3 行缓存 -> Sobel 边缘检测 -> 二值化 -> 叠加
    //  逐像素流水, 无帧缓存, 输出相对输入延迟恒为 1 行 + 4 像素。
    //  后续接入软核时, bypass / edge_thr / mode 改由寄存器组驱动即可。
    //--------------------------------------------------------------------------
    //==========================================================================
    //  视频时序测量
    //  自己数 de/hs/vs 量出实际分辨率, 不依赖 MS7200 的寄存器语义。
    //  结果挂在寄存器 0x04/0x08 上, MCU 可以直接读。
    //==========================================================================
    wire [11:0] h_act, v_act;
    wire [15:0] frame_cnt;
    wire        video_stable;
    wire [15:0] dbg_line;          // 诊断: 行结束计数

    video_timing u_video_timing (
        .pix_clk    (  pixclk_out        ),
        .rstn       (  init_over_sync    ),
        .de         (  vid_in_r[2]       ),
        .vs         (  vid_in_r[0]       ),
        .h_act      (  h_act             ),
        .v_act      (  v_act             ),
        .frame_cnt  (  frame_cnt         ),
        .stable     (  video_stable      ),
        .dbg_line_cnt ( dbg_line          )
    );

    //==========================================================================
    //  软核 + 寄存器组 (基础任务2: 软硬协同)
    //  PicoRV32 跑在 cfg_clk(10MHz) 域, 通过寄存器组控制视频流水线。
    //  MCU 只碰"结果"和"参数", 永远不碰像素 —— 数据量差 6~7 个数量级。
    //==========================================================================
    wire [ 7:0] rb_addr;
    wire [31:0] rb_wdata, rb_rdata;
    wire        rb_we, rb_re;
    wire [ 7:0] led_dbg;
    wire        cpu_trap;

    picosoc_lane u_soc (
        .clk       (  cfg_clk        ),
        .resetn    (  rstn_out       ),
        .ser_tx    (  uart_txd       ),
        .ser_rx    (  uart_rxd       ),
        .rb_addr   (  rb_addr        ),
        .rb_wdata  (  rb_wdata       ),
        .rb_we     (  rb_we          ),
        .rb_re     (  rb_re          ),
        .rb_rdata  (  rb_rdata       ),
        .led       (  led_dbg        ),
        .cpu_trap  (  cpu_trap       )
    );

    wire        cfg_en, cfg_bypass;
    wire [ 1:0] cfg_mode;
    wire [ 7:0] cfg_edge_thr, cfg_lane_w, cfg_led;
    wire [11:0] cfg_roi_top, cfg_roi_bot;

    reg_bank u_reg_bank (
        .clk           (  cfg_clk        ),
        .rstn          (  rstn_out       ),
        .addr          (  rb_addr        ),
        .wdata         (  rb_wdata       ),
        .we            (  rb_we          ),
        .re            (  rb_re          ),
        .rdata         (  rb_rdata       ),
        .h_act         (  h_act_s        ),
        .v_act         (  v_act_s        ),
        .frame_cnt     (  frame_cnt_s    ),
        .video_stable  (  stable_s       ),
        .det_cnt       (  8'd0           ),
        .cfg_en        (  cfg_en         ),
        .cfg_bypass    (  cfg_bypass     ),
        .cfg_mode      (  cfg_mode       ),
        .cfg_edge_thr  (  cfg_edge_thr   ),
        .cfg_roi_top   (  cfg_roi_top    ),
        .cfg_roi_bot   (  cfg_roi_bot    ),
        .cfg_lane_w    (  cfg_lane_w     ),
        .cfg_led       (  cfg_led        ),
        .dbg_line      (  dbg_line_s     )      // 临时: 源已改成上传链路调试字
    );

    //--------------------------------------------------------------------------
    //  跨时钟域同步
    //  寄存器组在 cfg_clk 域, 视频流水线在像素域。两边交换的全是准静态信号,
    //  两级触发器足够, 不需要握手。
    //  frame_cnt 是 16 位计数器, 逐位同步偶尔会读到"半新半旧"的值 ——
    //  作为状态监视无害; 将来要做精确计时再改格雷码。
    //--------------------------------------------------------------------------
    reg [11:0] h_act_s1,     h_act_s;
    reg [11:0] v_act_s1,     v_act_s;
    reg [15:0] frame_cnt_s1, frame_cnt_s;
    reg        stable_s1,    stable_s;
    reg [15:0] dbg_line_s1, dbg_line_s;

    always @(posedge cfg_clk) begin
        h_act_s1     <= h_act;
        h_act_s      <= h_act_s1;
        v_act_s1     <= v_act;
        v_act_s      <= v_act_s1;
        frame_cnt_s1 <= frame_cnt;
        frame_cnt_s  <= frame_cnt_s1;
        stable_s1    <= video_stable;
        stable_s     <= stable_s1;
        dbg_line_s1  <= dbg_line;
        dbg_line_s   <= dbg_line_s1;
    end

    reg [ 1:0] mode_s1,   mode_s;
    reg        bypass_s1, bypass_s;
    reg [ 7:0] ethr_s1,   ethr_s;

    always @(posedge pixclk_out) begin
        mode_s1   <= cfg_mode;
        mode_s    <= mode_s1;
        bypass_s1 <= cfg_bypass;
        bypass_s  <= bypass_s1;
        ethr_s1   <= cfg_edge_thr;
        ethr_s    <= ethr_s1;
    end
    //------------------------------------------------------------------------
    //  video_process（灰度/Sobel/车道线叠加）已移出设计：
    //  显示固定为原图直通，检测框由 OSD 叠加。
    //  源文件还在 source/ 下，需要时把上面注掉的例化恢复即可。
    //------------------------------------------------------------------------
    wire        vp_de = vid_in_r[2];
    wire [7:0]  vp_r  = vid_in_r[26:19];
    wire [7:0]  vp_g  = vid_in_r[18:11];
    wire [7:0]  vp_b  = vid_in_r[10:3];

    //------------------------------------------------------------------
    //  输出寄存级（DE/HS/VS/R/G/B 六个信号在同一个 always 块里寄存）
    //  1) 六者严格对齐 -> 不会出现 DE 比 HS 晚几 ns，画面不抖
    //  2) 这些寄存器还被上传通路读取（内部扇出），综合不会把它们
    //     吸进 I/O 单元；吸进去后画框数据会丢（图像正常但看不到框）
    //------------------------------------------------------------------
    wire        osd_de;
    wire [7:0]  osd_r, osd_g, osd_b;

    reg         de_r, hs_r, vs_r;
    reg  [7:0]  rr, gr, br;








//----------------------------------------------------------------------------
//  千兆以太网视频上传
//    net_clk 由 PHY 的 rgmii_rxc 经 PLL 产生（125MHz），自成时钟域。
//    注意 phy_rstn 绝不能由 PLL 锁定驱动：那会形成
//    "复位 -> PHY 没时钟 -> PLL 锁不上 -> 一直复位" 的死锁。
//----------------------------------------------------------------------------
    wire        net_clk;
    wire        net_clk_90p;
    wire        net_rstn;
    wire [7:0]  net_dly;

    wire        net_tx_en;
    wire [7:0]  net_txd;
    wire        net_rx_valid;
    wire [7:0]  net_rx_data;

    ref_clock u_net_pll (
        .clkout0 ( net_clk_90p ),
        .lock    ( net_rstn    ),
        .clkin1  ( rgmii_rxc   )
    );

    // PHY 复位由 rstn_out (G25) 驱动，这里不再重复驱动。

    rgmii_interface u_rgmii (
        .rst               ( ~net_rstn    ),
        .rgmii_clk         ( net_clk      ),
        .rgmii_clk_90p     (              ),
        .mac_tx_data_valid ( net_tx_en    ),
        .mac_tx_data       ( net_txd      ),
        .mac_rx_error      (              ),
        .mac_rx_data_valid ( net_rx_valid ),
        .mac_rx_data       ( net_rx_data  ),
        .rgmii_rxc         ( net_clk_90p  ),
        .rgmii_rx_ctl      ( rgmii_rx_ctl ),
        .rgmii_rxd         ( rgmii_rxd    ),
        .rgmii_txc         ( rgmii_txc    ),
        .rgmii_tx_ctl      ( rgmii_tx_ctl ),
        .rgmii_txd         ( rgmii_txd    ),
        .dbg_delay         ( net_dly      )
    );

    wire [31:0] net_frame_cnt;
    wire        net_busy;

    // 上传源选择（运行时寄存器，不能用 localparam）：
    //   bypass = 0（默认）→ 上传原始画面，模型看到的是干净图像
    //   bypass = 1        → 上传叠加后画面（调试画框位置用）
    //
    // 【为什么必须用寄存器而不是参数常量】
    //   OSD 的输出寄存器如果只驱动外部端口，综合会把它吸收进 I/O 单元
    //   （OREGIS）。被吸收后画框数据会丢失 —— 图像正常但屏幕上看不到框。
    //   只要让这些寄存器还有一个内部扇出（这里就是上传 mux），
    //   它就吸不进去，画框才正常。实测踩过这个坑。
    // 上传取"输出寄存级"的值。
    //
    // 【不要改成 vid_in_r！】实测过：改成直接取原始输入后，屏幕上就不画框了。
    // 这一级寄存器必须保留内部扇出（上传通路就是它的扇出），
    // 否则综合会把它优化进 I/O 单元，画框数据就丢失。
    // 代价是模型看到的画面里带有画好的框（2 像素细线，实测不影响检测）。
    wire       up_de = de_r;
    wire [7:0] up_r  = rr;
    wire [7:0] up_g  = gr;
    wire [7:0] up_b  = br;

    net_video_uplink u_uplink (
        .pix_clk   ( pixclk_out     ),
        .pix_rstn  ( init_over_sync ),
        .de_in     ( up_de          ),
        .r_in      ( up_r           ),
        .g_in      ( up_g           ),
        .b_in      ( up_b           ),
        .net_clk   ( net_clk        ),
        .net_rstn  ( net_rstn       ),
        .tx_en     ( net_tx_en      ),
        .txd       ( net_txd        ),
        .frame_cnt ( net_frame_cnt  ),
        .link_busy ( net_busy       )
    );

//----------------------------------------------------------------------------
//  检测结果接收 + OSD 叠加
//----------------------------------------------------------------------------
    wire [31:0] box_fid;
    wire [7:0]  box_nbox;
    wire [511:0] box_x1, box_y1, box_x2, box_y2;
    wire [255:0] box_cls, box_sub, box_conf;
    wire         box_new;

    net_rx_path u_rx (
        .net_clk  ( net_clk    ),
        .net_rstn ( net_rstn   ),
        .rx_dv    ( net_rx_valid ),
        .rx_data  ( net_rx_data  ),
        .pix_clk  ( pixclk_out ),
        .pix_rstn ( init_over_sync ),
        .o_fid    ( box_fid    ),
        .o_nbox   ( box_nbox   ),
        .o_x1     ( box_x1     ),
        .o_y1     ( box_y1     ),
        .o_x2     ( box_x2     ),
        .o_y2     ( box_y2     ),
        .o_cls    ( box_cls    ),
        .o_sub    ( box_sub    ),
        .o_conf   ( box_conf   ),
        .o_new    ( box_new    )
    );

    // ---- 诊断模式 ----
    //  OSD_DIAG = 1: 框位置写死，颜色表示"是否收到过检测结果"
    //               绿框 = 从没收到过；红框 = 收到过至少一次
    //  OSD_DIAG = 0: 正常模式，用 RX 收到的框
    localparam OSD_DIAG = 0;
    localparam FORCE_COORD = 0;   // 1 = 坐标写死，只让框数来自 RX

    // 网络域：原始帧计数（每收到一帧翻转一次）
    reg raw_d, raw_tog;
    always @(posedge net_clk) begin
        if(!net_rstn) begin
            raw_d   <= 1'b0;
            raw_tog <= 1'b0;
        end
        else begin
            raw_d <= net_rx_valid;
            if(net_rx_valid && !raw_d) raw_tog <= ~raw_tog;
        end
    end

    reg [2:0] raw_sync;
    reg       raw_seen, rx_seen;
    always @(posedge pixclk_out) begin
        if(!init_over_sync) begin
            raw_sync <= 3'b000;
            raw_seen <= 1'b0;
            rx_seen  <= 1'b0;
        end
        else begin
            raw_sync <= {raw_sync[1:0], raw_tog};
            if(raw_sync[1] ^ raw_sync[2]) raw_seen <= 1'b1;
            if(box_new)                   rx_seen  <= 1'b1;
        end
    end

    // 白 = 一帧原始数据都没收到；绿 = 收到帧但解析失败；红 = 解析成功
    wire [7:0] diag_cls = rx_seen  ? 8'd2      // 红
                        : raw_seen ? 8'd0      // 绿
                        :            8'd3;     // 白

    wire [7:0]   osd_nbox = OSD_DIAG ? 8'd1 : box_nbox;
    wire [511:0] osd_x1   = (OSD_DIAG||FORCE_COORD) ? {{(512-16){1'b0}}, 16'd200} : box_x1;
    wire [511:0] osd_y1   = (OSD_DIAG||FORCE_COORD) ? {{(512-16){1'b0}}, 16'd150} : box_y1;
    wire [511:0] osd_x2   = (OSD_DIAG||FORCE_COORD) ? {{(512-16){1'b0}}, 16'd800} : box_x2;
    wire [511:0] osd_y2   = (OSD_DIAG||FORCE_COORD) ? {{(512-16){1'b0}}, 16'd500} : box_y2;
    // 类别 0 = 绿, 2 = 红
    wire [255:0] osd_cls  = OSD_DIAG ? {{(256-8){1'b0}}, diag_cls} : box_cls;
    wire [255:0] osd_sub  = OSD_DIAG ? 256'd0 : box_sub;   // 交通灯颜色

    osd_overlay #(
        .NBOX  ( 32 ),
        .H_ACT ( 1280 ),
        .V_ACT ( 720  )
    ) u_osd (
        .pix_clk ( pixclk_out     ),
        .rstn    ( init_over_sync ),
        .de_in   ( vp_de          ),
        .r_in    ( vp_r           ),
        .g_in    ( vp_g           ),
        .b_in    ( vp_b           ),
        .enable  ( 1'b1           ),
        .nbox    ( osd_nbox       ),
        .bx1     ( osd_x1         ),
        .by1     ( osd_y1         ),
        .bx2     ( osd_x2         ),
        .by2     ( osd_y2         ),
        .bcls    ( osd_cls        ),
        .bsub    ( osd_sub        ),
        .de_out  ( osd_de         ),
        .r_out   ( osd_r          ),
        .g_out   ( osd_g          ),
        .b_out   ( osd_b          )
    );

    // DE/HS/VS/RGB 六个信号一起寄存，保证严格对齐
    always @(posedge pixclk_out) begin
        if(!init_over_sync) begin
            de_r <= 1'b0;  hs_r <= 1'b0;  vs_r <= 1'b0;
            rr   <= 8'd0;  gr   <= 8'd0;  br   <= 8'd0;
        end
        else begin
            de_r <= osd_de;
            hs_r <= vid_in_r[1];
            vs_r <= vid_in_r[0];
            rr   <= osd_r;
            gr   <= osd_g;
            br   <= osd_b;
        end
    end

    assign de_out = de_r;
    assign hs_out = hs_r;
    assign vs_out = vs_r;
    assign r_out  = rr;
    assign g_out  = gr;
    assign b_out  = br;

endmodule
