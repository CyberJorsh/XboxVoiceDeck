#include "DeckAudio.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <mach/mach_time.h>

#define TAPS 32
#define PHASES 512
#define MAX_CHANNELS 32
#define TONE_ACTIVE UINT64_C(1)
#define OUTPUT_MUTED UINT64_C(2)
#define NEXT_COMMAND UINT64_C(4)
#define LOAD(x) atomic_load_explicit(&(x), memory_order_relaxed)
#define STORE(x, v) atomic_store_explicit(&(x), (v), memory_order_relaxed)
#define ADD(x, v) atomic_fetch_add_explicit(&(x), (v), memory_order_relaxed)

struct DeckSafety { _Atomic int32_t error; };
struct DeckRoute {
    float *ring;
    uint32_t capacity, channels, target;
    double nominalRatio, outputRate;
    bool xbox;
    // Each index has exactly one writer. Acquire/release protects sample storage.
    _Atomic uint64_t written, read;
    float coefficients[PHASES + 1][TAPS];
    double fraction, integral, filteredError, correction;
    bool primed;
    float gain, outputRamp, fade, limiterGain, releaseCoefficient;
    _Atomic float inputGain, outputGain;
    _Atomic float inputRMS, inputPeak, outputRMS, outputPeak, inputLeft, inputRight;
    _Atomic uint64_t inputClips, outputClips, limitedSamples;
    _Atomic uint64_t underruns, overruns, droppedFrames, resyncs;
    _Atomic uint64_t inputCallbacks, outputCallbacks;
    _Atomic uint32_t buffered;
    _Atomic double ppm;
    _Atomic bool ready;
    _Atomic uint64_t toneCommand, toneDeadline, toneFrames, limiterFrames;
    _Atomic uint32_t toneFramesRemaining;
    _Atomic float limiterReductionDB;
    uint64_t seenToneCommand, toneDurationTicks;
    uint32_t tonePosition;
};
struct DeckCapture {
    DeckRoute *route;
    DeckSafety *safety;
    AudioUnit unit;
    AudioBufferList *buffers;
    uint32_t channels, first, maxFrames;
    float *storage;
};
struct DeckOutput {
    DeckRoute *route;
    DeckSafety *safety;
    uint32_t channels, maxFrames;
    float *left, *right;
};

static double clampd(double x, double low, double high) { return fmax(low, fmin(high, x)); }
static float clean(float x) { return isfinite(x) ? x : 0; }

DeckSafety *DeckSafetyCreate(void) {
    DeckSafety *s = calloc(1, sizeof(*s));
    if (s && !atomic_is_lock_free(&s->error)) { free(s); return NULL; }
    return s;
}
void DeckSafetyDestroy(DeckSafety *s) { free(s); }
void DeckSafetyTrip(DeckSafety *s, int32_t error) {
    int32_t expected = 0;
    atomic_compare_exchange_strong(&s->error, &expected, error ? error : -1);
}
int32_t DeckSafetyError(DeckSafety *s) { return atomic_load_explicit(&s->error, memory_order_acquire); }

DeckRoute *DeckRouteCreate(double inRate, double outRate, uint32_t inBuffer,
                           uint32_t outBuffer, uint32_t channels, bool xbox) {
    if ((inRate != 44100 && inRate != 48000) || (outRate != 44100 && outRate != 48000) ||
        !inBuffer || inBuffer > 4096 || !outBuffer || outBuffer > 4096 || channels < 1 || channels > 2) return NULL;
    DeckRoute *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    if (!atomic_is_lock_free(&r->written) || !atomic_is_lock_free(&r->inputGain) ||
        !atomic_is_lock_free(&r->ppm) || !atomic_is_lock_free(&r->toneCommand) || !atomic_is_lock_free(&r->buffered)) {
        free(r); return NULL;
    }
    r->nominalRatio = inRate / outRate;
    r->outputRate = outRate;
    r->channels = channels;
    r->xbox = xbox;
    r->target = (uint32_t)fmax(inBuffer, ceil(outBuffer * r->nominalRatio)) * 3 + TAPS;
    r->capacity = 16384;
    while (r->capacity < r->target * 8) r->capacity *= 2;
    r->ring = calloc(r->capacity * channels, sizeof(float));
    if (!r->ring) { free(r); return NULL; }
    STORE(r->inputGain, 1);
    STORE(r->outputGain, xbox ? 0.001f : 0.1f);
    STORE(r->toneCommand, OUTPUT_MUTED);
    r->limiterGain = 1;
    r->releaseCoefficient = (float)(1 - exp(-1 / (outRate * 0.1)));
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.numer == 0) { DeckRouteDestroy(r); return NULL; }
    r->toneDurationTicks = (uint64_t)(2000000000.0 * timebase.denom / timebase.numer);
    // Blackman-windowed sinc, normalized per fractional phase. Leave transition
    // bandwidth below Nyquist, including the maximum adaptive ratio correction.
    double cutoff = 0.90 / fmax(1, r->nominalRatio * 1.002);
    for (int p = 0; p <= PHASES; ++p) {
        double sum = 0;
        for (int k = 0; k < TAPS; ++k) {
            double x = k - (TAPS / 2 - 1) - (double)p / PHASES;
            double sinc = fabs(x) < 1e-12 ? cutoff : sin(M_PI * cutoff * x) / (M_PI * x);
            double window = 0.42 - 0.5 * cos(2 * M_PI * k / (TAPS - 1)) + 0.08 * cos(4 * M_PI * k / (TAPS - 1));
            r->coefficients[p][k] = (float)(sinc * window);
            sum += r->coefficients[p][k];
        }
        for (int k = 0; k < TAPS; ++k) r->coefficients[p][k] /= sum;
    }
    return r;
}
void DeckRouteDestroy(DeckRoute *r) { if (r) { free(r->ring); free(r); } }
void DeckRouteSetLevels(DeckRoute *r, float inGain, float outDB) {
    STORE(r->inputGain, (float)clampd(clean(inGain), 0, 4));
    double db = isfinite(outDB) ? outDB : -90;
    STORE(r->outputGain, (float)pow(10, clampd(db, -90, r->xbox ? -30 : 0) / 20));
}
static void finishTone(DeckRoute *r, uint64_t command) {
    // Publish cancellation and its mute latch together. A callback must never
    // see an inactive tone with the previous unmuted state. The generation also
    // prevents a late completion from canceling a newer request.
    uint64_t finished = ((command + NEXT_COMMAND) & ~TONE_ACTIVE) | OUTPUT_MUTED;
    if ((command & TONE_ACTIVE) && atomic_compare_exchange_strong(&r->toneCommand, &command, finished)) {
        STORE(r->toneFramesRemaining, 0);
    }
}
void DeckRouteCancelTone(DeckRoute *r) {
    uint64_t command = atomic_load_explicit(&r->toneCommand, memory_order_acquire);
    finishTone(r, command);
}
void DeckRouteSetMuted(DeckRoute *r, bool mute) {
    if (mute) {
        atomic_fetch_or(&r->toneCommand, OUTPUT_MUTED);
        DeckRouteCancelTone(r);
    } else atomic_fetch_and(&r->toneCommand, ~OUTPUT_MUTED);
}
void DeckRouteSetGain(DeckRoute *r, float inGain, float outDB, bool mute) {
    DeckRouteSetLevels(r, inGain, outDB);
    DeckRouteSetMuted(r, mute);
}
bool DeckRouteStartTone(DeckRoute *r) {
    if (!r->xbox || !LOAD(r->ready)) return false;
    uint64_t command = atomic_load_explicit(&r->toneCommand, memory_order_acquire);
    if (command & (TONE_ACTIVE | OUTPUT_MUTED)) return false;
    STORE(r->outputGain, fminf(LOAD(r->outputGain), 0.001f));
    STORE(r->toneDeadline, mach_continuous_time() + r->toneDurationTicks);
    return atomic_compare_exchange_strong(&r->toneCommand, &command, (command + NEXT_COMMAND) | TONE_ACTIVE);
}
void DeckRouteBypass(DeckRoute *r) { DeckRouteCancelTone(r); STORE(r->inputGain, 1); }

void DeckRoutePush(DeckRoute *r, const float *left, const float *right, uint32_t frames) {
    ADD(r->inputCallbacks, 1);
    uint64_t w = LOAD(r->written);
    uint64_t rd = atomic_load_explicit(&r->read, memory_order_acquire);
    double power = 0, powers[2] = {0, 0};
    float peak = 0;
    uint64_t clips = 0;
    for (uint32_t i = 0; i < frames; ++i) {
        for (uint32_t ch = 0; ch < r->channels; ++ch) {
            float v = clean(ch && right ? right[i] : left[i]);
            powers[ch] += (double)v * v;
            peak = fmaxf(peak, fabsf(v));
            if (fabsf(v) >= 1) ++clips;
        }
    }
    power = powers[0] + powers[1];
    STORE(r->inputRMS, frames ? (float)sqrt(power / (frames * r->channels)) : 0);
    STORE(r->inputLeft, frames ? (float)sqrt(powers[0] / frames) : 0);
    STORE(r->inputRight, frames ? (float)sqrt(powers[r->channels == 2 ? 1 : 0] / frames) : 0);
    STORE(r->inputPeak, fmaxf(LOAD(r->inputPeak), peak));
    ADD(r->inputClips, clips);
    if (frames > r->capacity - (w - rd)) {
        ADD(r->overruns, 1); ADD(r->droppedFrames, frames); return;
    }
    for (uint32_t i = 0; i < frames; ++i) {
        uint32_t slot = (uint32_t)(w + i) & (r->capacity - 1);
        r->ring[slot * r->channels] = clean(left[i]);
        if (r->channels == 2) r->ring[slot * 2 + 1] = clean(right ? right[i] : left[i]);
    }
    atomic_store_explicit(&r->written, w + frames, memory_order_release);
}

void DeckRoutePull(DeckRoute *r, float *left, float *right, uint32_t frames) {
    ADD(r->outputCallbacks, 1);
    memset(left, 0, frames * sizeof(float));
    if (right) memset(right, 0, frames * sizeof(float));
    uint64_t rd = LOAD(r->read);
    uint64_t w = atomic_load_explicit(&r->written, memory_order_acquire);
    uint64_t available = w - rd;
    STORE(r->buffered, (uint32_t)available);
    STORE(r->outputRMS, 0);
    if (!r->primed) {
        if (available < r->target) return;
        if (available > r->target) ADD(r->droppedFrames, available - r->target);
        rd = w - r->target;
        available = r->target;
        r->fraction = r->integral = r->filteredError = r->correction = 0;
        r->fade = 0;
        r->primed = true;
        STORE(r->ready, true);
    }
    if (available > r->target * 2) {
        ADD(r->droppedFrames, available - r->target); ADD(r->resyncs, 1);
        rd = w - r->target; available = r->target;
        r->fraction = r->integral = r->filteredError = r->correction = 0;
        r->fade = 0;
        DeckRouteCancelTone(r);
    }
    double dt = frames / r->outputRate;
    double error = ((double)available - r->target) / r->target;
    r->filteredError += (1 - exp(-dt / 0.5)) * (error - r->filteredError);
    r->integral = clampd(r->integral + r->filteredError * dt * 0.0004, -0.002, 0.002);
    r->correction = clampd(r->filteredError * 0.002 + r->integral, -0.002, 0.002);
    STORE(r->ppm, r->correction * 1000000);
    double ratio = r->nominalRatio * (1 + r->correction);
    if (available < (uint64_t)ceil(r->fraction + frames * ratio) + TAPS) {
        ADD(r->underruns, 1); ADD(r->resyncs, 1); ADD(r->droppedFrames, available);
        atomic_store_explicit(&r->read, w, memory_order_release);
        r->primed = false; r->gain = 0; r->outputRamp = 0; r->fade = 0;
        STORE(r->ready, false);
        DeckRouteCancelTone(r);
        return;
    }
    float target = LOAD(r->inputGain);
    uint64_t command = atomic_load_explicit(&r->toneCommand, memory_order_acquire);
    if ((command & TONE_ACTIVE) && mach_continuous_time() >= LOAD(r->toneDeadline)) finishTone(r, command);
    if (command != r->seenToneCommand) { r->tonePosition = 0; r->seenToneCommand = command; }
    float slew = (float)(1 - exp(-1 / (r->outputRate * 0.01)));
    float peak = 0;
    double power = 0;
    uint64_t limited = 0, clips = 0, limiterFrames = 0, toneFrames = 0;
    for (uint32_t i = 0; i < frames; ++i) {
        r->gain += (target - r->gain) * slew;
        r->fade = fminf(1, r->fade + (float)(1 / (r->outputRate * 0.005)));
        double phase = r->fraction * PHASES;
        int p = (int)phase;
        float blend = (float)(phase - p);
        float samples[2] = {0, 0};
        float signalPeak = 0;
        uint64_t state = atomic_load_explicit(&r->toneCommand, memory_order_acquire);
        bool tone = (command & TONE_ACTIVE) && command == state;
        // A command arriving mid-buffer takes effect as silence until the next
        // callback initializes its tone position; never substitute live mic.
        bool mute = (state & OUTPUT_MUTED) || state != command;
        if (tone && mute) { finishTone(r, command); tone = false; }
        for (uint32_t ch = 0; ch < r->channels; ++ch) {
            float v = 0;
            for (uint32_t k = 0; k < TAPS; ++k) {
                float c = r->coefficients[p][k] + blend * (r->coefficients[p + 1][k] - r->coefficients[p][k]);
                uint32_t slot = (uint32_t)(rd + k) & (r->capacity - 1);
                v += r->ring[slot * r->channels + ch] * c;
            }
            // Calibration tone replaces the microphone; it cannot acquire mic
            // input gain or enter the incoming/headphone route.
            if (tone) {
                double envelope = fmin(1, fmin(r->tonePosition, 2 * r->outputRate - 1 - r->tonePosition) / (0.01 * r->outputRate));
                v = (float)(0.0316227766 * envelope * sin(2 * M_PI * 440 * r->tonePosition / r->outputRate));
            } else v = clean(v * r->gain * r->fade);
            samples[ch] = v;
            signalPeak = fmaxf(signalPeak, fabsf(v));
        }
        // Instant attack, 100 ms exponential release, no look-ahead delay.
        float desired = signalPeak > 0.89f ? 0.89f / signalPeak : 1;
        if (desired < r->limiterGain) r->limiterGain = desired;
        else r->limiterGain += (desired - r->limiterGain) * r->releaseCoefficient;
        if (r->limiterGain < 0.999f && !mute) ++limiterFrames;
        float outputGain = LOAD(r->outputGain);
        if (tone) outputGain = fminf(outputGain, 0.001f);
        if (mute) r->outputRamp = 0;
        else if (outputGain < r->outputRamp) r->outputRamp = outputGain;
        else r->outputRamp += (outputGain - r->outputRamp) * slew;
        for (uint32_t ch = 0; ch < r->channels; ++ch) {
            float v = clean(samples[ch] * r->limiterGain * r->outputRamp);
            float ceiling = r->xbox ? 0.95f * outputGain : 0.95f;
            if (fabsf(v) > ceiling) { ++limited; v = copysignf(ceiling, v); }
            if (mute) v = 0;
            if (fabsf(v) >= 1) ++clips;
            if (ch == 0) left[i] = v; else if (right) right[i] = v;
            power += (double)v * v;
            peak = fmaxf(peak, fabsf(v));
        }
        if (tone) {
            ++toneFrames;
            ++r->tonePosition;
            if (r->tonePosition >= (uint32_t)(2 * r->outputRate)) finishTone(r, command);
            else STORE(r->toneFramesRemaining, (uint32_t)(2 * r->outputRate) - r->tonePosition);
        }
        if (r->channels == 1 && right) right[i] = left[i];
        r->fraction += ratio;
        uint64_t advance = (uint64_t)r->fraction;
        rd += advance; r->fraction -= advance;
    }
    atomic_store_explicit(&r->read, rd, memory_order_release);
    STORE(r->outputRMS, frames ? (float)sqrt(power / (frames * r->channels)) : 0);
    STORE(r->outputPeak, fmaxf(LOAD(r->outputPeak), peak));
    ADD(r->limitedSamples, limited); ADD(r->outputClips, clips);
    ADD(r->limiterFrames, limiterFrames); ADD(r->toneFrames, toneFrames);
    STORE(r->limiterReductionDB, -20 * log10f(fmaxf(r->limiterGain, 1e-20f)));
}

DeckSnapshot DeckRouteSnapshot(DeckRoute *r) {
    DeckSnapshot s = {0};
#define SNAP(field) s.field = LOAD(r->field)
    SNAP(inputRMS); SNAP(inputPeak); SNAP(outputRMS); SNAP(outputPeak);
    SNAP(inputLeft); SNAP(inputRight); SNAP(inputClips); SNAP(outputClips); SNAP(limitedSamples);
    SNAP(underruns); SNAP(overruns); SNAP(droppedFrames); SNAP(resyncs);
    SNAP(inputCallbacks); SNAP(outputCallbacks);
    SNAP(limiterReductionDB); SNAP(limiterFrames); SNAP(toneFrames); SNAP(toneFramesRemaining);
#undef SNAP
    s.bufferedFrames = LOAD(r->buffered); s.targetFrames = r->target; s.correctionPPM = LOAD(r->ppm);
    uint64_t state = atomic_load_explicit(&r->toneCommand, memory_order_acquire);
    s.muted = (state & OUTPUT_MUTED) != 0; s.toneActive = (state & TONE_ACTIVE) != 0;
    if (!s.toneActive) s.toneFramesRemaining = 0;
    return s;
}

DeckCapture *DeckCaptureCreate(DeckRoute *r, DeckSafety *s, AudioUnit unit,
                              uint32_t channels, uint32_t first, uint32_t maxFrames) {
    if (!channels || channels > MAX_CHANNELS || first + r->channels > channels || !maxFrames) return NULL;
    DeckCapture *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->route = r; c->safety = s; c->unit = unit; c->channels = channels; c->first = first; c->maxFrames = maxFrames;
    c->buffers = calloc(1, offsetof(AudioBufferList, mBuffers) + channels * sizeof(AudioBuffer));
    c->storage = calloc(channels * maxFrames, sizeof(float));
    if (!c->buffers || !c->storage) { DeckCaptureDestroy(c); return NULL; }
    c->buffers->mNumberBuffers = channels;
    for (uint32_t i = 0; i < channels; ++i) {
        c->buffers->mBuffers[i] = (AudioBuffer){1, maxFrames * sizeof(float), c->storage + i * maxFrames};
    }
    return c;
}
void DeckCaptureDestroy(DeckCapture *c) { if (c) { free(c->buffers); free(c->storage); free(c); } }
DeckOutput *DeckOutputCreate(DeckRoute *r, DeckSafety *s, uint32_t channels, uint32_t maxFrames) {
    if (!channels || channels > MAX_CHANNELS || !maxFrames) return NULL;
    DeckOutput *o = calloc(1, sizeof(*o));
    if (!o) return NULL;
    o->route = r; o->safety = s; o->channels = channels; o->maxFrames = maxFrames;
    o->left = calloc(maxFrames, sizeof(float)); o->right = calloc(maxFrames, sizeof(float));
    if (!o->left || !o->right) { DeckOutputDestroy(o); return NULL; }
    return o;
}
void DeckOutputDestroy(DeckOutput *o) { if (o) { free(o->left); free(o->right); free(o); } }
AURenderCallbackStruct DeckMakeCallback(bool capture, void *context) {
    return (AURenderCallbackStruct){capture ? DeckInputCallback : DeckOutputCallback, context};
}
OSStatus DeckInputCallback(void *context, AudioUnitRenderActionFlags *flags,
                          const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)bus; (void)data;
    DeckCapture *c = context;
    if (DeckSafetyError(c->safety)) return noErr;
    if (frames > c->maxFrames) { DeckRouteSetMuted(c->route, true); DeckSafetyTrip(c->safety, kAudioUnitErr_TooManyFramesToProcess); return noErr; }
    for (uint32_t i = 0; i < c->channels; ++i) c->buffers->mBuffers[i].mDataByteSize = frames * sizeof(float);
    OSStatus status = AudioUnitRender(c->unit, flags, time, 1, frames, c->buffers);
    if (status) { DeckRouteSetMuted(c->route, true); DeckSafetyTrip(c->safety, status); return noErr; }
    for (uint32_t i = 0; i < c->channels; ++i) {
        if (!c->buffers->mBuffers[i].mData || c->buffers->mBuffers[i].mDataByteSize < frames * sizeof(float)) {
            DeckRouteSetMuted(c->route, true); DeckSafetyTrip(c->safety, kAudio_ParamError); return noErr;
        }
    }
    const float *left = c->buffers->mBuffers[c->first].mData;
    const float *right = c->route->channels == 2 ? c->buffers->mBuffers[c->first + 1].mData : left;
    DeckRoutePush(c->route, left, right, frames);
    return noErr;
}
OSStatus DeckOutputCallback(void *context, AudioUnitRenderActionFlags *flags,
                           const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)time; (void)bus;
    DeckOutput *o = context;
    if (!data) { DeckRouteSetMuted(o->route, true); DeckSafetyTrip(o->safety, kAudio_ParamError); return noErr; }
    for (uint32_t i = 0; i < data->mNumberBuffers; ++i) {
        if (data->mBuffers[i].mData) memset(data->mBuffers[i].mData, 0, data->mBuffers[i].mDataByteSize);
    }
    if (DeckSafetyError(o->safety)) { DeckRouteSetMuted(o->route, true); *flags |= kAudioUnitRenderAction_OutputIsSilence; return noErr; }
    if (frames > o->maxFrames || data->mNumberBuffers != o->channels) {
        DeckRouteSetMuted(o->route, true); DeckSafetyTrip(o->safety, kAudioUnitErr_TooManyFramesToProcess); return noErr;
    }
    for (uint32_t i = 0; i < data->mNumberBuffers; ++i) {
        if (!data->mBuffers[i].mData || data->mBuffers[i].mNumberChannels != 1 || data->mBuffers[i].mDataByteSize < frames * sizeof(float)) {
            DeckRouteSetMuted(o->route, true); DeckSafetyTrip(o->safety, kAudio_ParamError); return noErr;
        }
    }
    DeckRoutePull(o->route, o->left, o->right, frames);
    if (DeckSafetyError(o->safety)) { DeckRouteSetMuted(o->route, true); return noErr; }
    memcpy(data->mBuffers[0].mData, o->left, frames * sizeof(float));
    if (o->channels > 1) memcpy(data->mBuffers[1].mData, o->right, frames * sizeof(float));
    // Channels above the selected stereo pair stay zero, never mirror arbitrary buses.
    return noErr;
}
