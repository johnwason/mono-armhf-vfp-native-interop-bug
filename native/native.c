// Native side of the reproducer. Built as libnative.so for armhf:
//   arm-linux-gnueabihf-gcc -O2 -shared -fPIC -o libnative.so native.c probe.S -lpthread
//
// Two kinds of check:
//
//   probe_run*      Exact: loads known patterns into every callee-saved
//                   register (d8-d15, r4-r11) and a stack slot, calls the
//                   managed callback, and records which ones changed.
//                   See probe.S.
//
//   loop_check*     Realistic: an ordinary C loop whose local double lives in
//                   a callee-saved VFP register across the callback, the same
//                   way GCC compiles RobotRaconteur::ThreadPool::thread_function.
//                   This is how the bug was first hit.
//
// The *_on_thread variants run the check on a pthread the managed runtime has
// never seen, like a native library's worker thread.

#include <pthread.h>
#include <stdint.h>
#include <string.h>

typedef void (*cb_t)(void);

// ---------------------------------------------------------------------------
// Exact probe

#define PROBE_SLOTS 17  // d8..d15, r4..r11, stack canary

struct probe_state
{
    uint64_t d[8];
    uint32_t r[8];
    uint32_t canary[2];
    uint64_t d7; // input only: a marker in caller-saved d7 at the call
};

void vfp_probe(cb_t cb, const struct probe_state* in, struct probe_state* out);

static void fill_patterns(struct probe_state* s, uint32_t iter)
{
    // Distinct, recognisable, and different on every call, so a stale value
    // left over from an earlier call cannot pass by accident.
    for (int i = 0; i < 8; i++)
    {
        s->d[i] = 0x4D00000000000000ull | ((uint64_t)(8 + i) << 48) | ((uint64_t)iter << 16) | 0xD0u;
        s->r[i] = 0xA0000000u | ((uint32_t)(4 + i) << 24) | ((iter & 0xFFFFu) << 4) | 0x5u;
    }
    s->canary[0] = 0xDEADBEEFu ^ iter;
    s->canary[1] = 0xF00DD00Du ^ iter;
    s->d7 = 0x4D00000000000000ull | (7ull << 48) | ((uint64_t)iter << 16) | 0xD0u;
}

// The specific corruption seen with mono on armhf: d8-d15 come back shifted by
// one register, d(n+1) = caller's d(n) and d8 = caller's d7, as if restored
// from a save area that is off by one 8-byte slot.
static int is_shifted_by_one(const struct probe_state* in, const struct probe_state* out)
{
    if (out->d[0] != in->d7)
        return 0;
    for (int i = 1; i < 8; i++)
        if (out->d[i] != in->d[i - 1])
            return 0;
    return 1;
}

// counts[slot]: number of calls in which that slot changed.
// first[slot]:  the value found in that slot the first time it changed
//               (for r4-r11 and the canary, the low 32 bits).
// shifted:      number of calls whose d8-d15 match is_shifted_by_one exactly.
// Returns the number of calls in which anything changed.
int probe_run(cb_t cb, int n, int* counts, uint64_t* first, int* shifted)
{
    int bad_calls = 0;
    *shifted = 0;
    memset(counts, 0, PROBE_SLOTS * sizeof(int));
    memset(first, 0, PROBE_SLOTS * sizeof(uint64_t));

    for (int iter = 0; iter < n; iter++)
    {
        struct probe_state in, out;
        fill_patterns(&in, (uint32_t)iter);
        memset(&out, 0, sizeof(out));
        vfp_probe(cb, &in, &out);

        int bad = 0;
        for (int i = 0; i < 8; i++)
        {
            if (out.d[i] != in.d[i])
            {
                if (!counts[i]++) first[i] = out.d[i];
                bad = 1;
            }
            if (out.r[i] != in.r[i])
            {
                if (!counts[8 + i]++) first[8 + i] = out.r[i];
                bad = 1;
            }
        }
        if (out.canary[0] != in.canary[0] || out.canary[1] != in.canary[1])
        {
            if (!counts[16]++) first[16] = ((uint64_t)out.canary[1] << 32) | out.canary[0];
            bad = 1;
        }
        bad_calls += bad;
        *shifted += is_shifted_by_one(&in, &out);
    }
    return bad_calls;
}

struct probe_args
{
    cb_t cb;
    int n;
    int* counts;
    uint64_t* first;
    int* shifted;
    int result;
};

static void* probe_thread_main(void* p)
{
    struct probe_args* a = p;
    a->result = probe_run(a->cb, a->n, a->counts, a->first, a->shifted);
    return 0;
}

int probe_run_on_thread(cb_t cb, int n, int* counts, uint64_t* first, int* shifted)
{
    struct probe_args a = {cb, n, counts, first, shifted, 0};
    pthread_t t;
    if (pthread_create(&t, 0, probe_thread_main, &a) != 0)
        return -1;
    pthread_join(t, 0);
    return a.result;
}

// ---------------------------------------------------------------------------
// Realistic compiler-generated case

// volatile, so the expected value is re-read after every call instead of being
// kept in another callee-saved register; only `keep` lives across the call.
static volatile double expected = 3703.5;

int loop_check(cb_t cb, int n, double* first_bad)
{
    double keep = expected;
    int bad = 0;
    *first_bad = 0;
    for (int i = 0; i < n; i++)
    {
        cb();
        if (keep != expected)
        {
            if (!bad)
                *first_bad = keep;
            bad++;
            keep = expected;
        }
    }
    return bad;
}

struct loop_args
{
    cb_t cb;
    int n;
    double first_bad;
    int result;
};

static void* loop_thread_main(void* p)
{
    struct loop_args* a = p;
    a->result = loop_check(a->cb, a->n, &a->first_bad);
    return 0;
}

int loop_check_on_thread(cb_t cb, int n, double* first_bad)
{
    struct loop_args a = {cb, n, 0, 0};
    pthread_t t;
    if (pthread_create(&t, 0, loop_thread_main, &a) != 0)
        return -1;
    pthread_join(t, 0);
    *first_bad = a.first_bad;
    return a.result;
}
