# ============================================================================
#  PicoRV32 启动代码
#
#  PicoRV32 的 SP 由硬件参数 STACKADDR 预先设好（本工程 = 0x8000），
#  所以这里只需要清 .bss 然后跳 main。
# ============================================================================
    .section .text.init, "ax", @progbits
    .globl  _start

_start:
    la      t0, _bss_start
    la      t1, _bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b

2:  call    main

3:  j       3b                  # main 返回就停在这里
