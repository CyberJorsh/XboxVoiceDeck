#include "DeckAudio.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>

static void *render(void *context) {
    DeckEndpointTest *test = context;
    float left[128], right[128];
    for (int i = 0; i < 100; ++i) {
        DeckEndpointTestRender(test, left, right, 128);
        for (int f = 0; f < 128; ++f) {
            assert(isfinite(left[f]) && isfinite(right[f]));
            assert(fabsf(left[f]) <= 0.000101f && fabsf(right[f]) <= 0.000101f);
        }
    }
    return NULL;
}
int main(void) {
    for (int i = 0; i < 500; ++i) {
        DeckEndpointTest *test = DeckEndpointTestCreate(NULL, false, true, 48000, 2, 0, 2, 128);
        assert(test);
        pthread_t thread;
        assert(pthread_create(&thread, NULL, render, test) == 0);
        for (int j = 0; j < 100; ++j) {
            DeckEndpointTestSnapshot snapshot = DeckEndpointTestRead(test);
            assert(isfinite(snapshot.peak));
            if (j == 50) DeckEndpointTestCancel(test);
        }
        assert(pthread_join(thread, NULL) == 0);
        float left[128], right[128];
        DeckEndpointTestRender(test, left, right, 128);
        for (int f = 0; f < 128; ++f) assert(left[f] == 0 && right[f] == 0);
        assert(!DeckEndpointTestRead(test).active);
        DeckEndpointTestDestroy(test);
    }
    // Oversized callbacks silence the actual supplied buffers before rejecting.
    DeckEndpointTest *test = DeckEndpointTestCreate(NULL, false, true, 48000, 1, 0, 1, 32);
    assert(test);
    float samples[64]; for (int i = 0; i < 64; ++i) samples[i] = 1;
    AudioBufferList buffers = {1, {{1, sizeof(samples), samples}}};
    AURenderCallbackStruct callback = DeckEndpointTestCallback(test);
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp time = {0};
    callback.inputProc(test, &flags, &time, 0, 64, &buffers);
    for (int i = 0; i < 64; ++i) assert(samples[i] == 0);
    assert(DeckEndpointTestRead(test).error != 0);
    DeckEndpointTestDestroy(test);
    puts("500 concurrent endpoint tone/cancel/snapshot cycles and oversized callback silencing passed.");
    return 0;
}
