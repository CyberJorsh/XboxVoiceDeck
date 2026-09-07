#include "DeckAudio.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <mach/mach_time.h>

struct DeckEndpointTest {
    AudioUnit unit;
    DeckSafety *safety;
    bool capture, xbox;
    double rate;
    uint32_t channels, first, measured, maxFrames, position, duration;
    uint64_t deadline;
    AudioBufferList *buffers;
    float *storage;
    _Atomic bool active;
    _Atomic int32_t error;
    _Atomic float rms, peak, left, right;
    _Atomic uint64_t clips, callbacks, frames;
};

void DeckEndpointTestCancel(DeckEndpointTest *t) { atomic_store(&t->active, false); }
void DeckEndpointTestSetSafety(DeckEndpointTest *t, DeckSafety *safety) { t->safety = safety; }
static bool active(DeckEndpointTest *t) {
    return atomic_load(&t->active) && (!t->safety || !DeckSafetyError(t->safety));
}
void DeckEndpointTestDestroy(DeckEndpointTest *t) {
    if (t) { free(t->buffers); free(t->storage); free(t); }
}
static void fail(DeckEndpointTest *t, int32_t error) {
    int32_t expected = 0;
    atomic_compare_exchange_strong(&t->error, &expected, error);
    DeckEndpointTestCancel(t);
}
DeckEndpointTest *DeckEndpointTestCreate(AudioUnit unit, bool capture, bool xbox,
    double rate, uint32_t channels, uint32_t first, uint32_t measured, uint32_t maxFrames) {
    if ((rate != 44100 && rate != 48000) || !channels || channels > 32 ||
        !maxFrames || maxFrames > 4096 || !measured || measured > 2 ||
        first >= channels || measured > channels - first) return NULL;
    DeckEndpointTest *t = calloc(1, sizeof(*t));
    if (!t) return NULL;
    if (!atomic_is_lock_free(&t->active) || !atomic_is_lock_free(&t->rms) ||
        !atomic_is_lock_free(&t->frames) || !atomic_is_lock_free(&t->error)) { free(t); return NULL; }
    t->unit = unit; t->capture = capture; t->xbox = xbox; t->rate = rate;
    t->channels = channels; t->first = first; t->measured = measured; t->maxFrames = maxFrames;
    uint32_t seconds = capture ? 10 : 2;
    t->duration = (uint32_t)rate * seconds;
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.numer) { free(t); return NULL; }
    t->deadline = mach_continuous_time() + (uint64_t)(seconds * 1e9 * timebase.denom / timebase.numer);
    if (capture) {
        t->buffers = calloc(1, offsetof(AudioBufferList, mBuffers) + channels * sizeof(AudioBuffer));
        t->storage = calloc(channels * maxFrames, sizeof(float));
        if (!t->buffers || !t->storage) { DeckEndpointTestDestroy(t); return NULL; }
        t->buffers->mNumberBuffers = channels;
        for (uint32_t c = 0; c < channels; ++c)
            t->buffers->mBuffers[c] = (AudioBuffer){1, maxFrames * sizeof(float), t->storage + c * maxFrames};
    }
    atomic_store(&t->active, true);
    return t;
}
static bool ready(DeckEndpointTest *t, uint32_t frames) {
    if (frames > t->maxFrames) { fail(t, kAudioUnitErr_TooManyFramesToProcess); return false; }
    if (t->position >= t->duration || mach_continuous_time() >= t->deadline) DeckEndpointTestCancel(t);
    return active(t);
}
static void meter(DeckEndpointTest *t, double l, double r, float peak, uint64_t clips, uint32_t frames) {
    atomic_store(&t->left, frames ? sqrt(l / frames) : 0);
    atomic_store(&t->right, frames ? sqrt(r / frames) : 0);
    atomic_store(&t->rms, frames ? sqrt((l + (t->measured == 2 ? r : 0)) / (frames * t->measured)) : 0);
    atomic_store(&t->peak, fmaxf(atomic_load(&t->peak), peak));
    atomic_fetch_add(&t->clips, clips);
    atomic_fetch_add(&t->frames, frames);
    atomic_fetch_add(&t->callbacks, 1);
    if (t->position >= t->duration) DeckEndpointTestCancel(t);
}
void DeckEndpointTestFeed(DeckEndpointTest *t, const float *left, const float *right, uint32_t frames) {
    if (!t->capture || !ready(t, frames)) return;
    if (!left || (t->measured == 2 && !right)) { fail(t, kAudio_ParamError); return; }
    double l = 0, r = 0; float peak = 0; uint64_t clips = 0;
    uint32_t count = 0;
    for (; count < frames && t->position < t->duration && active(t); ++count, ++t->position) {
        float a = left[count], b = t->measured == 2 ? right[count] : 0;
        if (!isfinite(a)) { a = 0; ++clips; }
        if (!isfinite(b)) { b = 0; ++clips; }
        l += (double)a * a; r += (double)b * b;
        peak = fmaxf(peak, fmaxf(fabsf(a), fabsf(b)));
        clips += fabsf(a) >= 1; clips += fabsf(b) >= 1;
    }
    meter(t, l, r, peak, clips, count);
}
void DeckEndpointTestRender(DeckEndpointTest *t, float *left, float *right, uint32_t frames) {
    // Bounds are checked before touching caller buffers.
    if (frames > t->maxFrames) { fail(t, kAudioUnitErr_TooManyFramesToProcess); return; }
    if (left) memset(left, 0, frames * sizeof(float));
    if (right) memset(right, 0, frames * sizeof(float));
    if (t->capture || !ready(t, frames)) return;
    if (!left || (t->channels > 1 && !right)) { fail(t, kAudio_ParamError); return; }
    double l = 0, r = 0; float peak = 0;
    for (uint32_t i = 0; i < frames && t->position < t->duration && active(t); ++i, ++t->position) {
        uint32_t second = t->position / (uint32_t)t->rate;
        uint32_t local = t->position % (uint32_t)t->rate;
        double ramp = fmin(1, fmin(local, t->rate - 1 - local) / (0.01 * t->rate));
        // Fixed ceilings: Xbox -80 dBFS, headphones -50 dBFS. No saved gain applies.
        float sample = (float)(sin(2 * M_PI * (second ? 660 : 440) * local / t->rate) * ramp * (t->xbox ? 0.0001 : 0.00316227766));
        sample = fmaxf(t->xbox ? -0.0001f : -0.003162278f, fminf(t->xbox ? 0.0001f : 0.003162278f, sample));
        if (t->xbox || !second || t->channels == 1) left[i] = sample;
        if (right && (t->xbox || second)) right[i] = sample;
        l += (double)left[i] * left[i]; if (right) r += (double)right[i] * right[i];
        peak = fmaxf(peak, fabsf(sample));
    }
    meter(t, l, r, peak, 0, frames);
}
DeckEndpointTestSnapshot DeckEndpointTestRead(DeckEndpointTest *t) {
    return (DeckEndpointTestSnapshot){atomic_load(&t->rms), atomic_load(&t->peak), atomic_load(&t->left), atomic_load(&t->right),
        atomic_load(&t->clips), atomic_load(&t->callbacks), atomic_load(&t->frames), atomic_load(&t->error), active(t)};
}
static OSStatus callback(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
    UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)bus;
    DeckEndpointTest *t = context;
    if (!t->capture && data) for (uint32_t c = 0; c < data->mNumberBuffers; ++c)
        if (data->mBuffers[c].mData) memset(data->mBuffers[c].mData, 0, data->mBuffers[c].mDataByteSize);
    if (!ready(t, frames)) { if (flags) *flags |= kAudioUnitRenderAction_OutputIsSilence; return noErr; }
    if (t->capture) {
        for (uint32_t c = 0; c < t->channels; ++c) t->buffers->mBuffers[c].mDataByteSize = frames * sizeof(float);
        OSStatus status = AudioUnitRender(t->unit, flags, time, 1, frames, t->buffers);
        if (status) { fail(t, status); return noErr; }
        data = t->buffers;
    }
    if (!data || data->mNumberBuffers != t->channels) { fail(t, kAudio_ParamError); return noErr; }
    for (uint32_t c = 0; c < t->channels; ++c) if (!data->mBuffers[c].mData || data->mBuffers[c].mNumberChannels != 1 ||
        data->mBuffers[c].mDataByteSize < frames * sizeof(float)) { fail(t, kAudio_ParamError); return noErr; }
    if (t->capture) DeckEndpointTestFeed(t, data->mBuffers[t->first].mData, t->measured == 2 ? data->mBuffers[t->first + 1].mData : NULL, frames);
    else DeckEndpointTestRender(t, data->mBuffers[0].mData, t->channels > 1 ? data->mBuffers[1].mData : NULL, frames);
    return noErr;
}
AURenderCallbackStruct DeckEndpointTestCallback(DeckEndpointTest *t) { return (AURenderCallbackStruct){callback, t}; }
