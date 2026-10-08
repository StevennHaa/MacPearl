#ifndef MACPEARL_BROKER_PROBE_H
#define MACPEARL_BROKER_PROBE_H

#include "MacPearlCameraProbe.h"

MacPearlCameraProbeRef MacPearlBrokerProbeCreate(
    MacPearlCameraProbeCompletion completion,
    void *context
);
void MacPearlBrokerProbeStart(MacPearlCameraProbeRef probe);
void MacPearlBrokerProbeCancel(MacPearlCameraProbeRef probe);
void MacPearlBrokerProbeRelease(MacPearlCameraProbeRef probe);

#endif
