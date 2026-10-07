#ifndef MACPEARL_CAMERA_PROBE_H
#define MACPEARL_CAMERA_PROBE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    MacPearlCameraProbeOutcomeFrameReceived = 0,
    MacPearlCameraProbeOutcomePermissionUnavailable,
    MacPearlCameraProbeOutcomeNoCamera,
    MacPearlCameraProbeOutcomeConfigurationFailed,
    MacPearlCameraProbeOutcomeTimedOut,
    MacPearlCameraProbeOutcomeCancelled,
} MacPearlCameraProbeOutcome;

typedef struct {
    MacPearlCameraProbeOutcome outcome;
    int32_t authorizationStatus;
    uint32_t deviceCount;
    double firstFrameLatencyMilliseconds;
    char deviceType[32];
    char deviceIdentifierHash[17];
} MacPearlCameraProbeResult;

typedef void (*MacPearlCameraProbeCompletion)(
    void *context,
    const MacPearlCameraProbeResult *result
);

typedef void *MacPearlCameraProbeRef;

MacPearlCameraProbeRef MacPearlCameraProbeCreate(
    MacPearlCameraProbeCompletion completion,
    void *context
);
void MacPearlCameraProbeStart(MacPearlCameraProbeRef probe);
void MacPearlCameraProbeCancel(MacPearlCameraProbeRef probe);
void MacPearlCameraProbeRelease(MacPearlCameraProbeRef probe);

typedef struct {
    MacPearlCameraProbeRef (*create)(MacPearlCameraProbeCompletion, void *);
    void (*start)(MacPearlCameraProbeRef);
    void (*cancel)(MacPearlCameraProbeRef);
    void (*release)(MacPearlCameraProbeRef);
} MacPearlCameraProbeFunctions;

#ifdef __cplusplus
}
#endif

#endif
