// A native "worker" that runs a managed callback as a job, then calls a
// completion handler it kept in a callee-saved VFP register across the job.
//   arm-linux-gnueabihf-gcc -O2 -shared -fPIC -o libworker.so worker.c keep_in_d8.S

#include <stdio.h>

typedef void (*cb_t)(void);
typedef void (*done_t)(int);

const void* keep_in_d8(cb_t cb, const void* p);

static int completed;

static void on_done(int iteration)
{
    (void)iteration;
    completed++;
}

// Returns the number of completed jobs so far.
int run_job(cb_t cb, int iteration)
{
    done_t done = (done_t)keep_in_d8(cb, (const void*)on_done);
    if (done != on_done)
    {
        fprintf(stderr, "native: call %d: completion handler kept in d8 came back as %p instead of %p; calling it\n",
                iteration, (const void*)done, (const void*)on_done);
        fflush(stderr);
    }
    done(iteration);
    return completed;
}
