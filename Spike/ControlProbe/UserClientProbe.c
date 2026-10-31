// UserClientProbe: IOKit client for the ControlSpike dext's own user client
// (ADR 0003 option (a), spike v9). Talks to the dext without Core Audio.
//
// Usage:
//   UserClientProbe info               open type 'xlrc' and read version and timebase
//   UserClientProbe echo <n> <bytes>   n echo round trips of <bytes> bytes, checked and timed
//   UserClientProbe events <n> <us>    subscribe, ask for n events every <us> µs, measure delivery
//
// Build: clang -O2 -o UserClientProbe UserClientProbe.c -framework IOKit -framework CoreFoundation

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { kEcho = 0, kInfo = 1, kSubscribe = 2, kEvents = 3 };
static const uint32_t kUserClientType = 'xlrc';
static mach_timebase_info_data_t timebase;

static double ms(uint64_t ticks) { return (double)ticks * timebase.numer / timebase.denom / 1e6; }

static int compare(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static void summary(const char *label, double *values, size_t count) {
    if (count == 0) { printf("  %s: none\n", label); return; }
    qsort(values, count, sizeof *values, compare);
    printf("  %s ms: min %.3f p50 %.3f p90 %.3f p99 %.3f max %.3f\n", label, values[0], values[count / 2],
           values[count * 9 / 10], values[count * 99 / 100], values[count - 1]);
}

static io_connect_t open_spike(void) {
    CFMutableDictionaryRef match = IOServiceMatching("IOUserService");
    CFMutableDictionaryRef property = CFDictionaryCreateMutable(NULL, 1, &kCFTypeDictionaryKeyCallBacks,
                                                                &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(property, CFSTR("CFBundleIdentifier"), CFSTR("yt.felix.xlr.spike.driver"));
    CFDictionarySetValue(match, CFSTR(kIOPropertyMatchKey), property);
    CFRelease(property);
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (!service) { printf("service not found\n"); exit(1); }
    io_connect_t connect = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), kUserClientType, &connect);
    IOObjectRelease(service);
    printf("IOServiceOpen 'xlrc' -> 0x%x\n", kr);
    if (kr != KERN_SUCCESS) exit(1);
    return connect;
}

static void info(io_connect_t connect) {
    uint64_t out[3] = {0};
    uint32_t count = 3;
    kern_return_t kr = IOConnectCallScalarMethod(connect, kInfo, NULL, 0, out, &count);
    printf("info -> 0x%x: version %llu, timebase %llu/%llu\n", kr, out[0], out[1], out[2]);
}

static void echo(io_connect_t connect, int rounds, size_t bytes) {
    uint8_t *in = malloc(bytes), *out = malloc(bytes);
    double *times = calloc(rounds, sizeof *times);
    int ok = 0, mismatched = 0;
    kern_return_t last = KERN_SUCCESS;
    for (int i = 0; i < rounds; i++) {
        for (size_t j = 0; j < bytes; j++) in[j] = (uint8_t)(i + j);
        size_t outSize = bytes;
        uint64_t start = mach_absolute_time();
        kern_return_t kr = IOConnectCallStructMethod(connect, kEcho, in, bytes, out, &outSize);
        times[i] = ms(mach_absolute_time() - start);
        if (kr != KERN_SUCCESS) { last = kr; continue; }
        if (outSize == bytes && memcmp(in, out, bytes) == 0) ok++; else mismatched++;
    }
    printf("echo %d x %zu bytes: %d ok, %d mismatched, %d failed (last 0x%x)\n", rounds, bytes, ok, mismatched,
           rounds - ok - mismatched, last);
    summary("round trip", times, rounds);
    free(in); free(out); free(times);
}

struct events {
    dispatch_semaphore_t done;
    uint64_t expected, received, firstSeq, lastSeq, outOfOrder;
    uint64_t *arrivals;
    double *latencies;
};

// With exactly two values IOKit calls the IOAsyncCallback2 form, not the
// array form (v9 crashed treating seq as the array pointer).
static void event_callback(void *refcon, IOReturn result, void *arg0, void *arg1) {
    uint64_t arrival = mach_absolute_time();
    struct events *state = refcon;
    if (result != kIOReturnSuccess || state->received >= state->expected) return;
    uint64_t seq = (uint64_t)(uintptr_t)arg0, sent = (uint64_t)(uintptr_t)arg1;
    if (state->received == 0) state->firstSeq = seq;
    else if (seq != state->lastSeq + 1) state->outOfOrder++;
    state->lastSeq = seq;
    state->arrivals[state->received] = arrival;
    state->latencies[state->received] = arrival >= sent ? ms(arrival - sent) : -1;
    if (++state->received == state->expected) dispatch_semaphore_signal(state->done);
}

static void events(io_connect_t connect, uint64_t count, uint64_t intervalUs) {
    struct events state = { .done = dispatch_semaphore_create(0), .expected = count,
                            .arrivals = calloc(count, sizeof(uint64_t)), .latencies = calloc(count, sizeof(double)) };
    IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
    IONotificationPortSetDispatchQueue(port, dispatch_queue_create("events", DISPATCH_QUEUE_SERIAL));
    uint64_t reference[kOSAsyncRef64Count] = {0};
    reference[kIOAsyncCalloutFuncIndex] = (uint64_t)(uintptr_t)event_callback;
    reference[kIOAsyncCalloutRefconIndex] = (uint64_t)(uintptr_t)&state;
    kern_return_t kr = IOConnectCallAsyncScalarMethod(connect, kSubscribe, IONotificationPortGetMachPort(port),
                                                      reference, kIOAsyncCalloutCount, NULL, 0, NULL, NULL);
    printf("subscribe -> 0x%x\n", kr);
    if (kr != KERN_SUCCESS) exit(1);
    uint64_t input[2] = { count, intervalUs };
    uint64_t start = mach_absolute_time();
    kr = IOConnectCallScalarMethod(connect, kEvents, input, 2, NULL, NULL);
    printf("events -> 0x%x\n", kr);
    double expected = count * intervalUs / 1e6;
    dispatch_semaphore_wait(state.done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((expected + 3) * NSEC_PER_SEC)));
    double elapsed = ms(mach_absolute_time() - start) / 1000;
    uint64_t received = state.received;
    printf("events: asked %llu every %llu us; received %llu in %.2f s; seqs %llu-%llu, %llu out of order\n", count,
           intervalUs, received, elapsed, state.firstSeq, state.lastSeq, state.outOfOrder);
    double *gaps = calloc(received ? received : 1, sizeof(double));
    for (uint64_t i = 1; i < received; i++) gaps[i - 1] = ms(state.arrivals[i] - state.arrivals[i - 1]);
    summary("gap between events", gaps, received ? received - 1 : 0);
    summary("latency (dext timestamp to callback)", state.latencies, received);
    IONotificationPortDestroy(port);
    free(gaps); free(state.arrivals); free(state.latencies);
}

int main(int argc, char **argv) {
    mach_timebase_info(&timebase);
    if (argc < 2) goto usage;
    io_connect_t connect = open_spike();
    if (!strcmp(argv[1], "info")) info(connect);
    else if (!strcmp(argv[1], "echo") && argc == 4) echo(connect, atoi(argv[2]), strtoul(argv[3], NULL, 10));
    else if (!strcmp(argv[1], "events") && argc == 4) events(connect, strtoull(argv[2], NULL, 10), strtoull(argv[3], NULL, 10));
    else { IOServiceClose(connect); goto usage; }
    IOServiceClose(connect);
    return 0;
usage:
    printf("usage: UserClientProbe info | echo <n> <bytes> | events <n> <us>\n");
    return 2;
}
