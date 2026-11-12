/* CPUMath.c — see CPUMath.h for the conventions. C99, platform-free. */

#include "CPUMath.h"

#include <stdlib.h>

TACpuPercent ta_cpu_percent(uint64_t prev_cpu_ns, uint64_t cur_cpu_ns,
                            uint64_t prev_wall_ns, uint64_t cur_wall_ns,
                            int logical_threads) {
    TACpuPercent result;
    result.valid = 0;
    result.cpu_seconds = 0.0;
    result.pct_one_thread = 0.0;
    result.pct_total_hardware = 0.0;

    if (logical_threads < 1) {
        logical_threads = 1;
    }
    if (cur_wall_ns <= prev_wall_ns) {
        return result; /* no interval, no rate */
    }
    if (cur_cpu_ns < prev_cpu_ns) {
        return result; /* counter went backwards: pid reuse or reset */
    }

    double cpu_ns = (double)(cur_cpu_ns - prev_cpu_ns);
    double wall_ns = (double)(cur_wall_ns - prev_wall_ns);
    result.cpu_seconds = cpu_ns / 1.0e9;
    result.pct_one_thread = (cpu_ns / wall_ns) * 100.0;
    result.pct_total_hardware = result.pct_one_thread / (double)logical_threads;
    result.valid = 1;
    return result;
}

static int ta_double_cmp(const void *a, const void *b) {
    double da = *(const double *)a;
    double db = *(const double *)b;
    if (da < db) return -1;
    if (da > db) return 1;
    return 0;
}

double ta_median(const double *values, int count) {
    if (values == NULL || count <= 0) {
        return 0.0;
    }
    double *sorted = (double *)malloc(sizeof(double) * (size_t)count);
    if (sorted == NULL) {
        return 0.0;
    }
    for (int i = 0; i < count; i++) {
        sorted[i] = values[i];
    }
    qsort(sorted, (size_t)count, sizeof(double), ta_double_cmp);
    double median;
    if (count % 2 == 1) {
        median = sorted[count / 2];
    } else {
        median = (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0;
    }
    free(sorted);
    return median;
}
