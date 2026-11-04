// ============================================================================
//  PicoRV32 固件 —— 决策层
//
//  存储器映射（与 picosoc_lane.v / reg_bank.v 对应）:
//    0x8000  UART 分频
//    0x8010  UART 数据（写会把 CPU 停住直到发送完成，不需要轮询）
//    0x8020 + (reg<<2)  reg_bank
//    0x8420  调试 LED
//
//  跑通这个文件就说明"软核 ↔ FPGA 寄存器"整条链路是通的。
// ============================================================================
#include <stdint.h>

// CPU 时钟 = cfg_clk = PLL 的 CLKOUT0 = 10 MHz。
// 这个值必须和实际时钟一致, 否则 UART 分频算错, 串口全是乱码。
// (曾经按 50MHz 写过, 实际 23k 波特被 115200 采样 -> 乱码)
#define CLK_HZ      10000000u

#define UART_DIV    (*(volatile uint32_t *)0x8000)
#define UART_DAT    (*(volatile uint32_t *)0x8010)
#define LED         (*(volatile uint32_t *)0x8420)
#define RB_BASE     0x8020u

#define REG(a)      (*(volatile uint32_t *)(RB_BASE + ((a) << 2)))

// ---- 寄存器索引（与 reg_bank.v 一一对应）----
#define R_MAGIC     0x00               // 只读，0x504E4750 = "PNGP"
#define R_TIMING    0x04               // {v_act[11:0], h_act[11:0]}
#define R_STATUS    0x08               // {frame_cnt[15:0], 15'b0, stable}
#define R_DET_CNT   0x0C               // 预留给检测模块
#define R_CTRL      0x10               // {28'b0, en, bypass, mode[1:0]}
#define R_EDGE_THR  0x14
#define R_ROI       0x18               // {8'b0, roi_bot[11:0], roi_top[11:0]}
#define R_LANE_W    0x1C
#define R_LED       0x20
#define R_DBG       0x24               // 诊断: 行结束计数(自由运行)

#define MAGIC_OK    0x504E4750u

// ============================================================================
//  最小 libc 补充
//  -nostdlib 下没有 libc，但 GCC 有可能把结构体/数组拷贝优化成 memcpy，
//  所以要自己提供这两个。其它需要的符号也是同样的办法补。
// ============================================================================
void *memcpy(void *dst, const void *src, unsigned int n)
{
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    while (n--) *d++ = *s++;
    return dst;
}

void *memset(void *dst, int c, unsigned int n)
{
    unsigned char *d = (unsigned char *)dst;
    while (n--) *d++ = (unsigned char)c;
    return dst;
}

// ============================================================================
//  UART 输出。写入 UART_DAT 时总线会自动停顿到发送完成，所以不需要轮询。
// ============================================================================
static void uart_init(void)
{
    UART_DIV = CLK_HZ / 115200u;
}

static void putc_(char c)
{
    UART_DAT = (uint32_t)(uint8_t)c;
}

static void puts_(const char *s)
{
    while (*s) putc_(*s++);
}

static void put_hex(uint32_t v)
{
    static const char H[] = "0123456789abcdef";
    puts_("0x");
    for (int i = 28; i >= 0; i -= 4) putc_(H[(v >> i) & 0xF]);
}

static void put_dec(uint32_t v)
{
    char b[11];
    int n = 0;
    if (v == 0) { putc_('0'); return; }
    while (v && n < 10) { b[n++] = (char)('0' + v % 10); v /= 10; }
    while (n) putc_(b[--n]);
}

static void delay(volatile uint32_t n)
{
    while (n--) __asm__ volatile ("nop");
}

// ============================================================================
//  车道线时序平滑 —— MCU 干这个最划算
//  FPGA 每帧给出原始的车道线 x 位置，这里做指数平滑，抑制帧间抖动。
//  一行代码的事，在 FPGA 里做要额外的算术和存储。
// ============================================================================
__attribute__((unused))
static int32_t smooth(int32_t prev, int32_t now)
{
    if (now < 0) return prev;                 // 本帧无效，沿用上次
    if (prev < 0) return now;                 // 首次
    return (prev * 7 + now) / 8;              // alpha = 1/8
}

// ============================================================================
int main(void)
{
    uart_init();

    puts_("\r\n=== PicoRV32 boot ===\r\n");

    // ---- 1. 确认链路 ----
    uint32_t magic = REG(R_MAGIC);
    puts_("magic = ");
    put_hex(magic);
    puts_(magic == MAGIC_OK ? "  OK\r\n" : "  FAIL\r\n");

    // ---- 2. 等视频时序稳定，再读分辨率 ----
    // init_over 要等 MS7210 的 I2C 配置完成（约 0.3 秒）才拉高，之后
    // video_timing 才开始统计。上电后立刻读的话 H_ACT/frame_cnt 全是 0。
    // 这里轮询 R_STATUS 的 bit0（video_stable），最多等约 5 秒。
    uint32_t st = 0;
    for (uint32_t i = 0; i < 5000000u; i++) {
        st = REG(R_STATUS);
        if (st & 1u) break;                 // bit0 = video_stable
    }

    uint32_t t = REG(R_TIMING);
    puts_("H_ACT = "); put_dec(t & 0xFFF);
    puts_("   V_ACT = "); put_dec((t >> 12) & 0xFFF);
    puts_("\r\n");

    st = REG(R_STATUS);
    puts_("video stable = "); put_dec(st & 1);
    puts_("   frame_cnt = "); put_dec(st >> 16);
    puts_("\r\n");

    // ---- 诊断: 行计数在不在涨 ----
    // 这个计数在像素域自由运行, 每遇到一个 de 下降沿就加一。
    // 读两次对比: 涨了说明 de 正常, 不变说明 de 根本没进来。
    uint32_t d1 = REG(R_DBG);
    for (volatile uint32_t w = 0; w < 2000000u; w++) {
        ;
    }
    uint32_t d2 = REG(R_DBG);
    puts_("line_cnt: ");  put_dec(d1);
    puts_(" -> ");        put_dec(d2);
    puts_(d2 != d1 ? "   在涨 (de 正常)\r\n" : "   不变 (de 没进来)\r\n");
    puts_("\r\n");

    // ---- 3. 固定显示原图，OSD 框叠加在其上 ----
    // 不再轮换模式：车道线识别已取消，显示固定为"原图 + 检测框"。
    // CTRL 位域: [1:0]=mode  [2]=bypass  [3]=en
    REG(R_CTRL) = 0x8u | 0u;                   // en=1, bypass=0, mode=0 (原图)
    LED         = 0x01;
    puts_("显示固定在 mode=0 (原图)，检测框由 OSD 叠加\r\n");

    // ---- 4. 主循环：心跳灯 ----
    // 空转 200 万次再翻转一次 LED0（板载 A20）。
    //
    // 【这是频率诊断用的】
    // 循环次数是固定的，所以闪烁快慢和 CPU 实际时钟成正比：
    //   约 1 秒翻转一次 -> 时钟 ≈ 10 MHz（符合预期）
    //   明显更快       -> 时钟比 10 MHz 高，快几倍就是几倍
    // 串口波特率调不出来时，靠这个就能反推真实时钟。
    uint32_t led = 0;
    for (;;) {
        for (volatile uint32_t d = 0; d < 2000000u; d++) {
            ;
        }
        led ^= 1u;
        LED = led;
    }
}
