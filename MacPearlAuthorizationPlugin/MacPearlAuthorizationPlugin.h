#ifndef MACPEARL_AUTHORIZATION_PLUGIN_H
#define MACPEARL_AUTHORIZATION_PLUGIN_H

#include <Security/AuthorizationPlugin.h>
#include "MacPearlCameraProbe.h"

#ifdef __cplusplus
extern "C" {
#endif

#define MACPEARL_FACE_UNLOCK_MECHANISM "FaceUnlock"
#define MACPEARL_CAMERA_PROBE_MECHANISM "CameraProbe"

OSStatus AuthorizationPluginCreate(
    const AuthorizationCallbacks *callbacks,
    AuthorizationPluginRef *outPlugin,
    const AuthorizationPluginInterface **outPluginInterface
);

// Available to the unit-test target. ExportedSymbols.txt keeps this private in
// the production authorization bundle.
void MacPearlAuthorizationPluginSetCameraProbeFunctionsForTesting(
    const MacPearlCameraProbeFunctions *functions
);

#ifdef __cplusplus
}
#endif

#endif
