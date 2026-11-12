#ifndef TA_CPU_MATH_H
#define TA_CPU_MATH_H

/* CPUMath — the portable heart of Tachometer (Detroit Automation Academy).
 *
 * Pure C99, no platform calls: the platform layer (ProcSampler) feeds it
 * cumulative CPU counters and wall-clock readings, both already converted
 * to nanoseconds, and it answers the only question Tachometer exists to
 * answer — how much of this machine's hardware did that process consume
 * across the interval?
 *
 * Conventions (stated once, used everywhere in the app):
 *   pct_one_thread     — 100% means one hardware thread fully busy for
 *                        the whole interval (the Activity Monitor scale).
 *   pct_total_hardware — pct_one_thread divided by the number of logical
 *                        threads; 100% means every thread on the machine
 *                        busy for the whole interval ("hardware cycles").
 */

#include <stdint.h>

typedef struct {
    int    valid;               /* 0 when the interval cannot support a rate */
    double cpu_seconds;         /* CPU consumed across the interval */
    double pct_one_thread;
    double pct_total_hardware;
} TACpuPercent;

/* Rate from cumulative counters. Invalid when the wall clock did not
 * advance or the CPU counter moved backwards (process restarted under a
 * reused pid, counter reset) — callers drop invalid rows rather than
 * printing a nonsense rate. logical_threads < 1 is clamped to 1. */
TACpuPercent ta_cpu_percent(uint64_t prev_cpu_ns, uint64_t cur_cpu_ns,
                            uint64_t prev_wall_ns, uint64_t cur_wall_ns,
                            int logical_threads);

/* Median of count values (count > 0). Copies before sorting; the caller's
 * array is untouched. Returns 0 for count <= 0. */
double ta_median(const double *values, int count);

#endif /* TA_CPU_MATH_H */
