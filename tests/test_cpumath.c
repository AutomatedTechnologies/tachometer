/* test_cpumath.c — Linux/gcc test harness for Tachometer's CPUMath core.
 * The delta math is the app's claim to truth; it is proven here, on the
 * build VM, before any macOS code is allowed to quote a percentage. */

#include <stdio.h>
#include <math.h>
#include "../Tachometer/CPUMath.h"

static int checks = 0;
static int failures = 0;

static void expect_close(const char *name, double got, double want) {
    checks++;
    if (fabs(got - want) > 1e-9) {
        failures++;
        printf("FAIL %s: got %.12f want %.12f\n", name, got, want);
    } else {
        printf("ok   %s = %.6f\n", name, got);
    }
}

static void expect_int(const char *name, int got, int want) {
    checks++;
    if (got != want) {
        failures++;
        printf("FAIL %s: got %d want %d\n", name, got, want);
    } else {
        printf("ok   %s = %d\n", name, got);
    }
}

int main(void) {
    const uint64_t S = 1000000000ULL; /* one second in ns */

    /* Half a thread busy for a full second on a 4-thread machine. */
    TACpuPercent r = ta_cpu_percent(0, S / 2, 0, S, 4);
    expect_int("half-thread valid", r.valid, 1);
    expect_close("half-thread pct_one_thread", r.pct_one_thread, 50.0);
    expect_close("half-thread pct_total_hardware", r.pct_total_hardware, 12.5);
    expect_close("half-thread cpu_seconds", r.cpu_seconds, 0.5);

    /* Two threads fully busy for a full second on 4 threads = half the machine. */
    r = ta_cpu_percent(10 * S, 12 * S, 100 * S, 101 * S, 4);
    expect_close("two-thread pct_one_thread", r.pct_one_thread, 200.0);
    expect_close("two-thread pct_total_hardware", r.pct_total_hardware, 50.0);

    /* Idle process: zero CPU across the interval is a valid 0%. */
    r = ta_cpu_percent(7 * S, 7 * S, 0, S, 4);
    expect_int("idle valid", r.valid, 1);
    expect_close("idle pct_one_thread", r.pct_one_thread, 0.0);

    /* No wall advance: no rate can be stated. */
    r = ta_cpu_percent(0, S, 5 * S, 5 * S, 4);
    expect_int("zero-wall invalid", r.valid, 0);

    /* Counter moving backwards (pid reuse): refuse, never print nonsense. */
    r = ta_cpu_percent(9 * S, 3 * S, 0, S, 4);
    expect_int("backwards-counter invalid", r.valid, 0);

    /* Thread count clamps at 1 (a bad sysctl read can never divide by 0). */
    r = ta_cpu_percent(0, S, 0, S, 0);
    expect_int("clamp valid", r.valid, 1);
    expect_close("clamp pct_total_hardware", r.pct_total_hardware, 100.0);

    /* Median: odd, even, single. */
    const double odd[] = {9.0, 1.0, 5.0};
    expect_close("median odd", ta_median(odd, 3), 5.0);
    const double even[] = {1.0, 2.0, 3.0, 10.0};
    expect_close("median even", ta_median(even, 4), 2.5);
    const double one[] = {42.0};
    expect_close("median single", ta_median(one, 1), 42.0);
    expect_close("median empty", ta_median(one, 0), 0.0);

    printf("---\n%d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
