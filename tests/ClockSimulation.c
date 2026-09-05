#include "DeckAudio.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void simulate(double inputRate, double outputRate, double ppm, unsigned inBlock, unsigned outBlock) {
    DeckRoute *r = DeckRouteCreate(inputRate, outputRate, inBlock, outBlock, 2, false);
    assert(r);
    DeckRouteSetGain(r, 1, 0, false);
    double actualRate = inputRate * (1 + ppm / 1000000);
    double nextIn = 0, nextOut = 0.0007;
    uint64_t inputFrame = 0, measured = 0, crossings = 0;
    float left[512], right[512], outL[512], outR[512], previous = 0;
    double energy = 0, isolation = 0;
    unsigned maxFill = 0;
    double correctionSum = 0;
    uint64_t correctionCount = 0;
    while (nextOut < 120) {
        if (nextIn <= nextOut) {
            for (unsigned i = 0; i < inBlock; ++i) {
                left[i] = (float)(0.2 * sin(2 * M_PI * 1000 * (inputFrame + i) / actualRate));
                right[i] = 0;
            }
            DeckRoutePush(r, left, right, inBlock);
            inputFrame += inBlock;
            nextIn += inBlock / actualRate;
        } else {
            DeckRoutePull(r, outL, outR, outBlock);
            DeckSnapshot s = DeckRouteSnapshot(r);
            if (s.bufferedFrames > maxFill) maxFill = s.bufferedFrames;
            if (nextOut > 60) { correctionSum += s.correctionPPM; ++correctionCount; }
            if (nextOut > 5) {
                for (unsigned i = 0; i < outBlock; ++i) {
                    assert(isfinite(outL[i]));
                    energy += outL[i] * outL[i];
                    isolation += outR[i] * outR[i];
                    if (previous <= 0 && outL[i] > 0) ++crossings;
                    previous = outL[i];
                    ++measured;
                }
            }
            nextOut += outBlock / outputRate;
        }
    }
    DeckSnapshot s = DeckRouteSnapshot(r);
    double rms = sqrt(energy / measured);
    double frequency = crossings / (measured / outputRate);
    printf("%.0f -> %.0f Hz, hardware %+.0f ppm, buffers %u/%u: correction %+.1f ppm, queue %u/%u max %u, under/over/resync %llu/%llu/%llu, RMS %.5f, frequency %.3f Hz\n",
        inputRate, outputRate, ppm, inBlock, outBlock, s.correctionPPM, s.bufferedFrames, s.targetFrames, maxFill,
        (unsigned long long)s.underruns, (unsigned long long)s.overruns, (unsigned long long)s.resyncs, rms, frequency);
    fflush(stdout);
    assert(s.underruns == 0 && s.overruns == 0 && s.resyncs == 0);
    assert(maxFill <= s.targetFrames * 2);
    // Occupancy includes block scheduling jitter. Assess convergence over the
    // final minute instead of mistaking one callback's correction for clock rate.
    printf("  Final-minute mean correction: %+.2f ppm\n", correctionSum / correctionCount);
    assert(fabs(correctionSum / correctionCount - ppm) < 40);
    assert(fabs(rms - 0.2 / sqrt(2)) < 0.003);
    assert(fabs(frequency - 1000) < 0.15);
    assert(isolation == 0);
    DeckRouteDestroy(r);
}

typedef struct { DeckRoute *route; _Atomic bool done; } ThreadContext;
static void *producer(void *arg) {
    ThreadContext *context = arg;
    float samples[128];
    for (unsigned i = 0; i < 128; ++i) samples[i] = (float)sin(i * 0.1) * 0.2f;
    for (unsigned block = 0; block < 20000; ++block) DeckRoutePush(context->route, samples, NULL, 128);
    atomic_store(&context->done, true);
    return NULL;
}
static void concurrency(void) {
    ThreadContext context = {.route = DeckRouteCreate(48000, 44100, 128, 128, 1, true), .done = false};
    assert(context.route);
    DeckRouteSetGain(context.route, 1, -60, false);
    pthread_t thread;
    assert(pthread_create(&thread, NULL, producer, &context) == 0);
    float output[128];
    do {
        DeckRoutePull(context.route, output, NULL, 128);
        for (unsigned i = 0; i < 128; ++i) assert(isfinite(output[i]) && fabsf(output[i]) <= 0.000951);
        (void)DeckRouteSnapshot(context.route);
    } while (!atomic_load(&context.done));
    assert(pthread_join(thread, NULL) == 0);
    printf("Concurrent producer/consumer completed: 20,000 producer blocks; bounded finite output.\n");
    DeckRouteDestroy(context.route);
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--threads-only") == 0) { concurrency(); return 0; }
    simulate(48000, 48000, 0, 128, 128);
    simulate(48000, 48000, 500, 128, 128);
    simulate(48000, 48000, -500, 128, 128);
    simulate(44100, 48000, 800, 128, 256);
    simulate(48000, 44100, -800, 256, 128);
    simulate(44100, 44100, 1000, 32, 64);
    simulate(48000, 48000, -1000, 512, 512);
    concurrency();
    puts("All clock, format, fidelity and isolation simulations passed.");
    return 0;
}
