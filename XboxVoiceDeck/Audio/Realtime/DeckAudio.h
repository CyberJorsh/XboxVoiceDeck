#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

// Opaque ownership: create/destroy on the control queue, after callbacks stop.
typedef struct DeckRoute DeckRoute;
typedef struct DeckCapture DeckCapture;
typedef struct DeckOutput DeckOutput;
typedef struct DeckSafety DeckSafety;

typedef struct {
    float inputRMS, inputPeak, outputRMS, outputPeak;
    float inputLeft, inputRight;
    uint64_t inputClips, outputClips, limitedSamples;
    uint64_t underruns, overruns, droppedFrames, resyncs;
    uint64_t primingDroppedFrames;
    uint64_t inputCallbacks, outputCallbacks;
    uint32_t bufferedFrames, targetFrames;
    double correctionPPM;
    float limiterReductionDB;
    uint64_t limiterFrames, toneFrames;
    uint32_t toneFramesRemaining;
    bool muted, toneActive;
} DeckSnapshot;

DeckSafety *DeckSafetyCreate(void);
void DeckSafetyDestroy(DeckSafety *safety);
void DeckSafetyTrip(DeckSafety *safety, int32_t error);
int32_t DeckSafetyError(DeckSafety *safety);

DeckRoute *DeckRouteCreate(double inputRate, double outputRate, uint32_t inputBuffer,
                           uint32_t outputBuffer, uint32_t channels, bool xbox);
void DeckRouteDestroy(DeckRoute *route);
// Control commands are serialized by AudioRoutingEngine. Render callbacks may
// independently latch mute/cancellation; level edits never override that latch.
void DeckRouteSetGain(DeckRoute *route, float inputGain, float outputDB, bool mute);
// Level edits never change mute state, including after a tone auto-mutes.
void DeckRouteSetLevels(DeckRoute *route, float inputGain, float outputDB);
void DeckRouteSetMuted(DeckRoute *route, bool mute);
// Caller must obtain explicit confirmation. Only an unmuted, primed Xbox route
// can start. Two seconds maximum; completion/cancellation latches output mute.
bool DeckRouteStartTone(DeckRoute *route);
void DeckRouteCancelTone(DeckRoute *route);
void DeckRouteBypass(DeckRoute *route);
DeckSnapshot DeckRouteSnapshot(DeckRoute *route);
// One producer and one consumer per route. These are also the simulation seam.
void DeckRoutePush(DeckRoute *route, const float *left, const float *right, uint32_t frames);
void DeckRoutePull(DeckRoute *route, float *left, float *right, uint32_t frames);

DeckCapture *DeckCaptureCreate(DeckRoute *route, DeckSafety *safety, AudioUnit unit,
                              uint32_t channels, uint32_t firstChannel, uint32_t maxFrames);
void DeckCaptureDestroy(DeckCapture *capture);
DeckOutput *DeckOutputCreate(DeckRoute *route, DeckSafety *safety, uint32_t channels, uint32_t maxFrames);
void DeckOutputDestroy(DeckOutput *output);
AURenderCallbackStruct DeckMakeCallback(bool capture, void *context);
OSStatus DeckInputCallback(void *context, AudioUnitRenderActionFlags *flags,
                          const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *data);
OSStatus DeckOutputCallback(void *context, AudioUnitRenderActionFlags *flags,
                           const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *data);
