@ const void *keep_in_d8(void (*cb)(void), const void *p);
@
@ Keeps p in the callee-saved register d8 while cb() runs, then returns it.
@ AAPCS-VFP requires cb to preserve d8, so the result must equal p. Any
@ callee-saved register may legally hold any data, including a pointer;
@ GCC did exactly this with d8 in the Boost.Asio scheduler where the
@ original crash happened. Written in assembly so it doesn't depend on the
@ compiler's register allocation.

    .syntax unified
    .arch   armv7-a
    .fpu    vfpv3-d16
    .arm
    .text
    .align  2
    .global keep_in_d8
    .type   keep_in_d8, %function
keep_in_d8:
    push    {r4, lr}            @ 8 bytes
    vpush   {d8}                @ 8 bytes, sp stays 8-byte aligned
    vmov    d8, r1, r1          @ d8 = p (in both halves)
    blx     r0                  @ cb()
    vmov    r0, r1, d8          @ r0 = what is left in d8
    vpop    {d8}
    pop     {r4, pc}
    .size   keep_in_d8, .-keep_in_d8

    .section .note.GNU-stack,"",%progbits
