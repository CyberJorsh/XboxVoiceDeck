#include "DeckAudio.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dispatch/dispatch.h>

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

// Local PRNG state makes every schedule repeatable and keeps capture and render
// jitter independent. Jitter is an absolute timestamp offset, not accumulated
// interval error that would accidentally introduce an unbounded clock walk.
static uint32_t randomNext(uint32_t *state) {
    uint32_t value = *state;
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    return *state = value;
}

static double timestampJitter(uint32_t *state) {
    return ((double)(randomNext(state) & 0xffff) / 65535 - 0.5) * 0.00015;
}

static unsigned variableBlock(uint32_t *state) {
    static const unsigned sizes[] = {32, 64, 128, 256};
    return sizes[randomNext(state) % 4];
}

static double changingDrift(double time) {
    if (time < 40) return 600;
    if (time < 60) return 600 - (time - 40) * 60;
    if (time < 90) return -600;
    return 350;
}

static void checkOutput(const float *left, const float *right, unsigned frames, float ceiling) {
    for (unsigned i = 0; i < frames; ++i) {
        assert(isfinite(left[i]) && fabsf(left[i]) <= ceiling);
        if (right) assert(isfinite(right[i]) && fabsf(right[i]) <= ceiling);
    }
}

static void variableSchedule(double inputRate, double outputRate, double duration, uint32_t seed) {
    DeckRoute *route = DeckRouteCreate(inputRate, outputRate, 256, 256, 2, false);
    assert(route);
    DeckRouteSetGain(route, 1, 0, false);
    uint32_t inputRandom = seed, outputRandom = seed ^ UINT32_C(0x9e3779b9);
    unsigned inputBlock = variableBlock(&inputRandom), outputBlock = variableBlock(&outputRandom);
    unsigned inputSizes = 0, outputSizes = 0, maxFill = 0;
    double inputTime = 0, outputTime = 0.0007;
    double nextInput = inputTime + timestampJitter(&inputRandom);
    double nextOutput = outputTime + timestampJitter(&outputRandom);
    double phase = 0, energy = 0, correctionIntegral = 0, measuredSeconds = 0, fillIntegral = 0;
    double earlyFillIntegral = 0, earlySeconds = 0;
    double positiveCorrection = 0, positiveSeconds = 0, negativeCorrection = 0, negativeSeconds = 0;
    uint64_t measured = 0, crossings = 0, stableDropped = 0;
    bool baselineCaptured = false;
    float left[256], right[256] = {0}, outLeft[256], outRight[256], previous = 0;
    while (outputTime < duration) {
        if (nextInput <= nextOutput) {
            double actualRate = inputRate * (1 + changingDrift(inputTime) / 1000000);
            for (unsigned i = 0; i < inputBlock; ++i) {
                left[i] = (float)(0.2 * sin(phase));
                phase += 2 * M_PI * 1000 / actualRate;
                if (phase >= 2 * M_PI) phase -= 2 * M_PI;
            }
            DeckRoutePush(route, left, right, inputBlock);
            inputSizes |= inputBlock;
            inputTime += inputBlock / actualRate;
            inputBlock = variableBlock(&inputRandom);
            nextInput = inputTime + timestampJitter(&inputRandom);
        } else {
            DeckRoutePull(route, outLeft, outRight, outputBlock);
            checkOutput(outLeft, outRight, outputBlock, 0.95f);
            DeckSnapshot snapshot = DeckRouteSnapshot(route);
            assert(snapshot.underruns == 0 && snapshot.overruns == 0 && snapshot.resyncs == 0);
            assert(snapshot.bufferedFrames <= snapshot.targetFrames * 2);
            assert(fabs(snapshot.correctionPPM) <= 2000);
            if (snapshot.bufferedFrames > maxFill) maxFill = snapshot.bufferedFrames;
            // Initial priming may discard a partial block. Healthy clock tracking
            // must not discard additional frames after that initial alignment.
            if (outputTime > 1 && !baselineCaptured) {
                stableDropped = snapshot.droppedFrames;
                baselineCaptured = true;
            }
            if (baselineCaptured) assert(snapshot.droppedFrames == stableDropped);
            double dt = outputBlock / outputRate;
            if (outputTime > duration - 60) {
                correctionIntegral += snapshot.correctionPPM * dt;
                fillIntegral += snapshot.bufferedFrames * dt;
                measuredSeconds += dt;
                for (unsigned i = 0; i < outputBlock; ++i) {
                    energy += outLeft[i] * outLeft[i];
                    assert(outRight[i] == 0);
                    if (previous <= 0 && outLeft[i] > 0) ++crossings;
                    previous = outLeft[i];
                    ++measured;
                }
            }
            if (duration > 180 && outputTime >= 120 && outputTime < 180) {
                earlyFillIntegral += snapshot.bufferedFrames * dt;
                earlySeconds += dt;
            }
            if (outputTime >= 30 && outputTime < 40) {
                positiveCorrection += snapshot.correctionPPM * dt;
                positiveSeconds += dt;
            }
            if (outputTime >= 75 && outputTime < 90) {
                negativeCorrection += snapshot.correctionPPM * dt;
                negativeSeconds += dt;
            }
            outputSizes |= outputBlock;
            outputTime += dt;
            outputBlock = variableBlock(&outputRandom);
            nextOutput = outputTime + timestampJitter(&outputRandom);
        }
    }
    DeckSnapshot snapshot = DeckRouteSnapshot(route);
    double correction = correctionIntegral / measuredSeconds;
    double meanFill = fillIntegral / measuredSeconds;
    double rms = sqrt(energy / measured), frequency = crossings / (measured / outputRate);
    printf("Variable %.0f -> %.0f Hz, %.0fs, seed %08x: drift +600 -> -600 -> +350 ppm, final-minute correction %+.2f ppm, mean queue %.1f/%u max %u, RMS %.5f, frequency %.3f Hz\n",
        inputRate, outputRate, duration, seed, correction, meanFill, snapshot.targetFrames, maxFill, rms, frequency);
    fflush(stdout);
    assert(inputSizes == (32 | 64 | 128 | 256) && outputSizes == inputSizes);
    assert(measuredSeconds > 59 && fabs(correction - 350) < 40);
    assert(fabs(meanFill - snapshot.targetFrames) < snapshot.targetFrames * 0.10);
    assert(fabs(rms - 0.2 / sqrt(2)) < 0.003 && fabs(frequency - 1000) < 0.15);
    assert(positiveSeconds > 9 && negativeSeconds > 14);
    assert(positiveCorrection / positiveSeconds > 300 && negativeCorrection / negativeSeconds < -300);
    printf("  Steady segment mean correction: %+.2f -> %+.2f ppm.\n",
        positiveCorrection / positiveSeconds, negativeCorrection / negativeSeconds);
    // The long session must settle at the same occupancy as its early settled
    // minute, rather than merely avoiding an overflow while latency grows.
    if (duration > 180) {
        assert(earlySeconds > 59);
        assert(fabs(meanFill - earlyFillIntegral / earlySeconds) < snapshot.targetFrames * 0.10);
        printf("  Early/final settled queue: %.1f/%.1f frames.\n", earlyFillIntegral / earlySeconds, meanFill);
    }
    DeckRouteDestroy(route);
}

static void recovery(bool overflow) {
    DeckRoute *route = DeckRouteCreate(48000, 48000, 128, 128, 1, true);
    assert(route);
    DeckRouteSetGain(route, 1, -60, false);
    float input[128], output[128];
    for (unsigned i = 0; i < 128; ++i) input[i] = 0.2f;
    for (unsigned block = 0; block < 1875; ++block) {
        DeckRoutePush(route, input, NULL, 128);
        DeckRoutePull(route, output, NULL, 128);
    }
    DeckSnapshot before = DeckRouteSnapshot(route);
    assert(before.underruns == 0 && before.overruns == 0 && before.resyncs == 0);
    assert(DeckRouteStartTone(route));
    if (overflow) {
        // Render callback stall: 256 capture blocks exceed this route's finite
        // ring capacity. This is an intentional fault, not a healthy-clock run.
        for (unsigned block = 0; block < 256; ++block) DeckRoutePush(route, input, NULL, 128);
        DeckRoutePull(route, output, NULL, 128);
        checkOutput(output, NULL, 128, 0.000951f);
    } else {
        // Capture callback stall: 64 renders drain the queue, then wait for
        // priming instead of counting the same starvation on every callback.
        for (unsigned block = 0; block < 64; ++block) {
            DeckRoutePull(route, output, NULL, 128);
            checkOutput(output, NULL, 128, 0.000951f);
        }
    }
    DeckSnapshot fault = DeckRouteSnapshot(route);
    assert(fault.resyncs == before.resyncs + 1);
    assert(fault.droppedFrames > before.droppedFrames);
    assert(fault.muted && !fault.toneActive && fault.toneFramesRemaining == 0);
    if (overflow) assert(fault.overruns > 0 && fault.underruns == 0);
    else assert(fault.underruns == 1 && fault.overruns == 0);

    unsigned recoveryBlock = 0;
    for (; recoveryBlock < 64; ++recoveryBlock) {
        DeckRoutePush(route, input, NULL, 128);
        DeckRoutePull(route, output, NULL, 128);
        for (unsigned i = 0; i < 128; ++i) assert(output[i] == 0);
        // Unmute is an explicit control action after the fault, never automatic.
        DeckRouteSetMuted(route, false);
        DeckRoutePush(route, input, NULL, 128);
        DeckRoutePull(route, output, NULL, 128);
        if (DeckRouteSnapshot(route).outputRMS > 0) break;
        DeckRouteSetMuted(route, true);
    }
    assert(recoveryBlock < 8); // Re-priming within 16 callbacks, under 43 ms.
    uint64_t settledDrops = DeckRouteSnapshot(route).droppedFrames;
    double correctionSum = 0, fillSum = 0;
    unsigned settledCount = 0, maxFill = 0;
    for (unsigned block = 0; block < 33750; ++block) { // 90 simulated seconds.
        DeckRoutePush(route, input, NULL, 128);
        DeckRoutePull(route, output, NULL, 128);
        checkOutput(output, NULL, 128, 0.000951f);
        DeckSnapshot current = DeckRouteSnapshot(route);
        assert(current.underruns == fault.underruns && current.overruns == fault.overruns && current.resyncs == fault.resyncs);
        assert(current.droppedFrames == settledDrops);
        assert(current.bufferedFrames <= current.targetFrames * 2);
        if (current.bufferedFrames > maxFill) maxFill = current.bufferedFrames;
        if (block >= 22500) { correctionSum += current.correctionPPM; fillSum += current.bufferedFrames; ++settledCount; }
    }
    DeckSnapshot final = DeckRouteSnapshot(route);
    assert(settledCount == 11250 && fabs(correctionSum / settledCount) < 40);
    assert(fabs(fillSum / settledCount - final.targetFrames) < final.targetFrames * 0.10);
    assert(final.outputRMS > 0.00019f && !final.muted && !final.toneActive);
    printf("Forced %s: under/over/resync %llu/%llu/%llu, dropped %llu, recovery <= %u callbacks, final 30s correction %+.2f ppm, mean queue %.1f/%u max %u; no subsequent faults.\n",
        overflow ? "render stall and capture burst" : "capture pause", (unsigned long long)final.underruns,
        (unsigned long long)final.overruns, (unsigned long long)final.resyncs, (unsigned long long)final.droppedFrames,
        (recoveryBlock + 1) * 2, correctionSum / settledCount, fillSum / settledCount, final.targetFrames, maxFill);
    fflush(stdout);
    DeckRouteDestroy(route);
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
static void *controller(void *arg) {
    ThreadContext *context = arg;
    for (unsigned i = 0; i < 20000; ++i) {
        DeckRouteSetLevels(context->route, i % 2 ? 2 : 1, -60);
        DeckRouteSetMuted(context->route, false);
        (void)DeckRouteStartTone(context->route);
        DeckRouteCancelTone(context->route);
    }
    return NULL;
}
static void concurrency(void) {
    ThreadContext context = {.route = DeckRouteCreate(48000, 44100, 128, 128, 1, true), .done = false};
    assert(context.route);
    DeckRouteSetGain(context.route, 1, -60, false);
    pthread_t thread;
    pthread_t controls;
    assert(pthread_create(&thread, NULL, producer, &context) == 0);
    assert(pthread_create(&controls, NULL, controller, &context) == 0);
    float output[128];
    do {
        DeckRoutePull(context.route, output, NULL, 128);
        for (unsigned i = 0; i < 128; ++i) assert(isfinite(output[i]) && fabsf(output[i]) <= 0.000951);
        (void)DeckRouteSnapshot(context.route);
    } while (!atomic_load(&context.done));
    assert(pthread_join(thread, NULL) == 0);
    assert(pthread_join(controls, NULL) == 0);
    printf("Concurrent producer/consumer/control completed: 20,000 producer blocks and tone/gain/mute command cycles; bounded finite output.\n");
    DeckRouteDestroy(context.route);
}

typedef struct {
    DeckRoute *route;
    dispatch_semaphore_t render, completed;
} CancellationContext;

static void *cancellationConsumer(void *arg) {
    CancellationContext *context = arg;
    float output[128];
    for (unsigned cycle = 0; cycle < 2000; ++cycle) {
        dispatch_semaphore_wait(context->render, DISPATCH_TIME_FOREVER);
        DeckRoutePull(context->route, output, NULL, 128);
        // The input is a much louder constant mic signal. Once tone start is
        // published, concurrent cancellation may yield tone or silence only.
        for (unsigned i = 0; i < 128; ++i) assert(isfinite(output[i]) && fabsf(output[i]) <= 0.0000317f);
        dispatch_semaphore_signal(context->completed);
    }
    return NULL;
}

static void cancellationIsolation(void) {
    CancellationContext context = {
        .route = DeckRouteCreate(48000, 48000, 128, 128, 1, true),
        .render = dispatch_semaphore_create(0), .completed = dispatch_semaphore_create(0)
    };
    assert(context.route && context.render && context.completed);
    float mic[128], output[128];
    for (unsigned i = 0; i < 128; ++i) mic[i] = 0.5f;
    for (unsigned block = 0; block < 100; ++block) {
        DeckRoutePush(context.route, mic, NULL, 128);
        DeckRoutePull(context.route, output, NULL, 128);
    }
    pthread_t consumer;
    assert(pthread_create(&consumer, NULL, cancellationConsumer, &context) == 0);
    for (unsigned cycle = 0; cycle < 2000; ++cycle) {
        DeckRoutePush(context.route, mic, NULL, 128);
        DeckRouteSetMuted(context.route, false);
        assert(DeckRouteStartTone(context.route));
        dispatch_semaphore_signal(context.render);
        if (cycle % 2) DeckRouteBypass(context.route);
        else DeckRouteCancelTone(context.route);
        dispatch_semaphore_wait(context.completed, DISPATCH_TIME_FOREVER);
        DeckSnapshot snapshot = DeckRouteSnapshot(context.route);
        assert(snapshot.muted && !snapshot.toneActive);
    }
    assert(pthread_join(consumer, NULL) == 0);
    dispatch_release(context.render);
    dispatch_release(context.completed);
    DeckRouteDestroy(context.route);
    puts("2,000 concurrent tone cancel/bypass render cycles passed: no live-mic substitution.");
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--threads-only") == 0) { concurrency(); cancellationIsolation(); return 0; }
    simulate(48000, 48000, 0, 128, 128);
    simulate(48000, 48000, 500, 128, 128);
    simulate(48000, 48000, -500, 128, 128);
    simulate(44100, 48000, 800, 128, 256);
    simulate(48000, 44100, -800, 256, 128);
    simulate(44100, 44100, 1000, 32, 64);
    simulate(48000, 48000, -1000, 512, 512);
    variableSchedule(48000, 48000, 180, UINT32_C(0x58424431));
    variableSchedule(44100, 48000, 180, UINT32_C(0x58424432));
    variableSchedule(48000, 44100, 600, UINT32_C(0x58424433));
    recovery(false);
    recovery(true);
    concurrency();
    cancellationIsolation();
    puts("All 10 healthy clock simulations, 2 forced-fault recovery simulations, and 2 concurrency scenarios passed.");
    return 0;
}
