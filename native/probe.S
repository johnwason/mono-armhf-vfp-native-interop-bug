@ Exact check of the AAPCS-VFP callee-saved state across a callback.
@
@ void vfp_probe(void (*cb)(void), const struct probe_state *in, struct probe_state *out);
@
@ struct probe_state {
@     uint64_t d[8];       // d8..d15        offset  0
@     uint32_t r[8];       // r4..r11        offset 64
@     uint32_t canary[2];  // a stack slot   offset 96
@     uint64_t d7;         // caller-saved d7 at the call (input only)  offset 104
@ };
@
@ Loads in->d into d8-d15, in->r into r4-r11 and in->canary into this
@ function's own stack frame, calls cb, then stores what is left in those
@ registers and that stack slot into *out. A conforming callee leaves them
@ unchanged, so out == in. The caller's real d8-d15 and r4-r11 are saved on
@ entry and restored on exit, so the probe itself is ABI-conforming.
@ d7 is caller-saved, so its value after the call is not checked; it is set
@ only so a callee that wrongly restores d8 from it can be recognised.
@
@ Written in assembly so the result does not depend on how a particular GCC
@ version allocates registers.

    .syntax unified
    .arch   armv7-a
    .fpu    vfpv3-d16
    .arm
    .text
    .align  2
    .global vfp_probe
    .type   vfp_probe, %function
vfp_probe:
    push    {r4-r11, lr}            @ 36 bytes
    sub     sp, sp, #12             @ out pointer + 8-byte canary; keeps sp 8-byte aligned
    vpush   {d8-d15}                @ 64 bytes, frame is now 112 bytes

    str     r2, [sp, #64]           @ save out pointer
    ldr     r3, [r1, #96]           @ canary into our own frame
    str     r3, [sp, #68]
    ldr     r3, [r1, #100]
    str     r3, [sp, #72]

    vldr    d7, [r1, #104]          @ d7 = in->d7 (caller-saved, marker only)
    vldmia  r1, {d8-d15}            @ d8-d15 = in->d
    add     r1, r1, #64
    ldmia   r1, {r4-r11}            @ r4-r11 = in->r

    blx     r0                      @ cb()

    ldr     r12, [sp, #64]          @ out pointer
    vstmia  r12!, {d8-d15}
    stmia   r12!, {r4-r11}
    ldr     r2, [sp, #68]
    ldr     r3, [sp, #72]
    stmia   r12, {r2, r3}

    vpop    {d8-d15}
    add     sp, sp, #12
    pop     {r4-r11, pc}
    .size   vfp_probe, .-vfp_probe

    .section .note.GNU-stack,"",%progbits
