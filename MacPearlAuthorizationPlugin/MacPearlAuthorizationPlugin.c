#include "MacPearlAuthorizationPlugin.h"

#include <os/log.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const AuthorizationCallbacks *callbacks;
} MacPearlPlugin;

typedef struct {
    MacPearlPlugin *plugin;
    AuthorizationEngineRef engine;
} MacPearlMechanism;

static os_log_t gMacPearlLog;

static void MacPearlInitializeLog(void)
{
    gMacPearlLog = os_log_create(
        "com.stevenha.MacPearl.AuthorizationPlugin",
        "lifecycle"
    );
}

static os_log_t MacPearlLog(void)
{
    static pthread_once_t onceToken = PTHREAD_ONCE_INIT;
    pthread_once(&onceToken, MacPearlInitializeLog);
    return gMacPearlLog;
}

static OSStatus MacPearlPluginDestroy(AuthorizationPluginRef inPlugin)
{
    if (inPlugin == NULL) {
        return errAuthorizationInternal;
    }

    os_log_info(MacPearlLog(), "Authorization plug-in destroyed");
    free(inPlugin);
    return errAuthorizationSuccess;
}

static OSStatus MacPearlMechanismCreate(
    AuthorizationPluginRef inPlugin,
    AuthorizationEngineRef inEngine,
    AuthorizationMechanismId mechanismId,
    AuthorizationMechanismRef *outMechanism
)
{
    if (outMechanism != NULL) {
        *outMechanism = NULL;
    }

    if (inPlugin == NULL || inEngine == NULL || mechanismId == NULL ||
        outMechanism == NULL ||
        strcmp(mechanismId, MACPEARL_FACE_UNLOCK_MECHANISM) != 0) {
        return errAuthorizationInternal;
    }

    MacPearlPlugin *plugin = (MacPearlPlugin *)inPlugin;
    if (plugin->callbacks == NULL || plugin->callbacks->SetResult == NULL ||
        plugin->callbacks->DidDeactivate == NULL) {
        return errAuthorizationInternal;
    }

    MacPearlMechanism *mechanism = calloc(1, sizeof(*mechanism));
    if (mechanism == NULL) {
        return errAuthorizationInternal;
    }

    mechanism->plugin = plugin;
    mechanism->engine = inEngine;
    *outMechanism = mechanism;
    os_log_info(MacPearlLog(), "FaceUnlock diagnostic mechanism created");
    return errAuthorizationSuccess;
}

static OSStatus MacPearlMechanismInvoke(AuthorizationMechanismRef inMechanism)
{
    if (inMechanism == NULL) {
        return errAuthorizationInternal;
    }

    MacPearlMechanism *mechanism = (MacPearlMechanism *)inMechanism;
    const AuthorizationCallbacks *callbacks = mechanism->plugin->callbacks;
    if (callbacks == NULL || callbacks->SetResult == NULL || mechanism->engine == NULL) {
        return errAuthorizationInternal;
    }

    // Phase 5.1A is diagnostic only. This mechanism must never authorize a user.
    os_log_info(MacPearlLog(), "FaceUnlock diagnostic mechanism invoked; denying by design");
    return callbacks->SetResult(mechanism->engine, kAuthorizationResultDeny);
}

static OSStatus MacPearlMechanismDeactivate(AuthorizationMechanismRef inMechanism)
{
    if (inMechanism == NULL) {
        return errAuthorizationInternal;
    }

    MacPearlMechanism *mechanism = (MacPearlMechanism *)inMechanism;
    const AuthorizationCallbacks *callbacks = mechanism->plugin->callbacks;
    if (callbacks == NULL || callbacks->DidDeactivate == NULL || mechanism->engine == NULL) {
        return errAuthorizationInternal;
    }

    os_log_info(MacPearlLog(), "FaceUnlock diagnostic mechanism deactivated");
    return callbacks->DidDeactivate(mechanism->engine);
}

static OSStatus MacPearlMechanismDestroy(AuthorizationMechanismRef inMechanism)
{
    if (inMechanism == NULL) {
        return errAuthorizationInternal;
    }

    os_log_info(MacPearlLog(), "FaceUnlock diagnostic mechanism destroyed");
    free(inMechanism);
    return errAuthorizationSuccess;
}

static const AuthorizationPluginInterface MacPearlPluginInterface = {
    .version = kAuthorizationPluginInterfaceVersion,
    .PluginDestroy = MacPearlPluginDestroy,
    .MechanismCreate = MacPearlMechanismCreate,
    .MechanismInvoke = MacPearlMechanismInvoke,
    .MechanismDeactivate = MacPearlMechanismDeactivate,
    .MechanismDestroy = MacPearlMechanismDestroy,
};

OSStatus AuthorizationPluginCreate(
    const AuthorizationCallbacks *callbacks,
    AuthorizationPluginRef *outPlugin,
    const AuthorizationPluginInterface **outPluginInterface
)
{
    if (outPlugin != NULL) {
        *outPlugin = NULL;
    }
    if (outPluginInterface != NULL) {
        *outPluginInterface = NULL;
    }

    if (callbacks == NULL || outPlugin == NULL || outPluginInterface == NULL ||
        callbacks->SetResult == NULL || callbacks->DidDeactivate == NULL) {
        return errAuthorizationInternal;
    }

    MacPearlPlugin *plugin = calloc(1, sizeof(*plugin));
    if (plugin == NULL) {
        return errAuthorizationInternal;
    }

    plugin->callbacks = callbacks;
    *outPlugin = plugin;
    *outPluginInterface = &MacPearlPluginInterface;
    os_log_info(MacPearlLog(), "Authorization plug-in created in diagnostic mode");
    return errAuthorizationSuccess;
}
