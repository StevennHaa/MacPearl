#ifndef MACPEARL_AUTHORIZATION_PLUGIN_H
#define MACPEARL_AUTHORIZATION_PLUGIN_H

#include <Security/AuthorizationPlugin.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MACPEARL_FACE_UNLOCK_MECHANISM "FaceUnlock"

OSStatus AuthorizationPluginCreate(
    const AuthorizationCallbacks *callbacks,
    AuthorizationPluginRef *outPlugin,
    const AuthorizationPluginInterface **outPluginInterface
);

#ifdef __cplusplus
}
#endif

#endif
