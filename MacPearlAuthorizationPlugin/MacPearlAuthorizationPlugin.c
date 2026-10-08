#include "MacPearlAuthorizationPlugin.h"
#include "MacPearlBrokerProbe.h"

#include <os/log.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

typedef enum {
    MacPearlMechanismKindFaceUnlock,
    MacPearlMechanismKindCameraProbe,
} MacPearlMechanismKind;

typedef struct {
    const AuthorizationCallbacks *callbacks;
} MacPearlPlugin;

typedef struct {
    const AuthorizationCallbacks *callbacks;
    AuthorizationEngineRef engine;
    MacPearlMechanismKind kind;
    pthread_mutex_t lock;
    unsigned int referenceCount;
    bool resultSent;
    bool deactivated;
    bool destroyed;
    bool invoked;
    bool probeCompletionHandled;
    MacPearlCameraProbeRef cameraProbe;
    MacPearlCameraProbeFunctions probeFunctions;
} MacPearlMechanism;

static os_log_t gMacPearlLog;
static pthread_mutex_t gProbeFunctionsLock = PTHREAD_MUTEX_INITIALIZER;
static MacPearlCameraProbeFunctions gProbeFunctions = {
    .create = MacPearlBrokerProbeCreate,
    .start = MacPearlBrokerProbeStart,
    .cancel = MacPearlBrokerProbeCancel,
    .release = MacPearlBrokerProbeRelease,
};

static void MacPearlInitializeLog(void)
{
    gMacPearlLog = os_log_create("com.stevenha.MacPearl.AuthorizationPlugin", "lifecycle");
}

static os_log_t MacPearlLog(void)
{
    static pthread_once_t onceToken = PTHREAD_ONCE_INIT;
    pthread_once(&onceToken, MacPearlInitializeLog);
    return gMacPearlLog;
}

static void MacPearlMechanismRetain(MacPearlMechanism *mechanism)
{
    pthread_mutex_lock(&mechanism->lock);
    mechanism->referenceCount += 1;
    pthread_mutex_unlock(&mechanism->lock);
}

static void MacPearlMechanismRelease(MacPearlMechanism *mechanism)
{
    bool shouldFree = false;
    pthread_mutex_lock(&mechanism->lock);
    mechanism->referenceCount -= 1;
    shouldFree = mechanism->referenceCount == 0;
    pthread_mutex_unlock(&mechanism->lock);
    if (shouldFree) {
        pthread_mutex_destroy(&mechanism->lock);
        free(mechanism);
    }
}

static OSStatus MacPearlSetDenyOnce(MacPearlMechanism *mechanism)
{
    bool shouldSetResult = false;
    pthread_mutex_lock(&mechanism->lock);
    if (!mechanism->resultSent && !mechanism->destroyed) {
        mechanism->resultSent = true;
        shouldSetResult = true;
    }
    pthread_mutex_unlock(&mechanism->lock);
    if (!shouldSetResult) {
        return errAuthorizationSuccess;
    }
    return mechanism->callbacks->SetResult(mechanism->engine, kAuthorizationResultDeny);
}

static void MacPearlCameraProbeCompleted(void *context, const MacPearlCameraProbeResult *result)
{
    MacPearlMechanism *mechanism = context;
    pthread_mutex_lock(&mechanism->lock);
    if (mechanism->probeCompletionHandled) {
        pthread_mutex_unlock(&mechanism->lock);
        return;
    }
    mechanism->probeCompletionHandled = true;
    pthread_mutex_unlock(&mechanism->lock);
    if (result != NULL) {
        os_log_info(
            MacPearlLog(),
            "Camera probe completed: outcome=%{public}d permission=%{public}d devices=%{public}u type=%{public}s id=%{public}s latency_ms=%{public}.1f",
            result->outcome, result->authorizationStatus, result->deviceCount,
            result->deviceType, result->deviceIdentifierHash,
            result->firstFrameLatencyMilliseconds
        );
    }
    MacPearlSetDenyOnce(mechanism);

    MacPearlCameraProbeRef probe = NULL;
    MacPearlCameraProbeFunctions functions;
    pthread_mutex_lock(&mechanism->lock);
    probe = mechanism->cameraProbe;
    mechanism->cameraProbe = NULL;
    functions = mechanism->probeFunctions;
    pthread_mutex_unlock(&mechanism->lock);
    if (probe != NULL) {
        functions.release(probe);
    }
    MacPearlMechanismRelease(mechanism);
}

static OSStatus MacPearlPluginDestroy(AuthorizationPluginRef inPlugin)
{
    if (inPlugin == NULL) return errAuthorizationInternal;
    free(inPlugin);
    return errAuthorizationSuccess;
}

static OSStatus MacPearlMechanismCreate(
    AuthorizationPluginRef inPlugin, AuthorizationEngineRef inEngine,
    AuthorizationMechanismId mechanismId, AuthorizationMechanismRef *outMechanism)
{
    if (outMechanism != NULL) *outMechanism = NULL;
    if (inPlugin == NULL || inEngine == NULL || mechanismId == NULL || outMechanism == NULL) {
        return errAuthorizationInternal;
    }
    MacPearlMechanismKind kind;
    if (strcmp(mechanismId, MACPEARL_FACE_UNLOCK_MECHANISM) == 0) {
        kind = MacPearlMechanismKindFaceUnlock;
    } else if (strcmp(mechanismId, MACPEARL_CAMERA_PROBE_MECHANISM) == 0) {
        kind = MacPearlMechanismKindCameraProbe;
    } else {
        return errAuthorizationInternal;
    }
    MacPearlPlugin *plugin = (MacPearlPlugin *)inPlugin;
    if (plugin->callbacks == NULL || plugin->callbacks->SetResult == NULL ||
        plugin->callbacks->DidDeactivate == NULL) return errAuthorizationInternal;

    MacPearlMechanism *mechanism = calloc(1, sizeof(*mechanism));
    if (mechanism == NULL || pthread_mutex_init(&mechanism->lock, NULL) != 0) {
        free(mechanism);
        return errAuthorizationInternal;
    }
    mechanism->callbacks = plugin->callbacks;
    mechanism->engine = inEngine;
    mechanism->kind = kind;
    mechanism->referenceCount = 1;
    *outMechanism = mechanism;
    return errAuthorizationSuccess;
}

static OSStatus MacPearlMechanismInvoke(AuthorizationMechanismRef inMechanism)
{
    if (inMechanism == NULL) return errAuthorizationInternal;
    MacPearlMechanism *mechanism = (MacPearlMechanism *)inMechanism;
    pthread_mutex_lock(&mechanism->lock);
    bool alreadyInvoked = mechanism->invoked;
    mechanism->invoked = true;
    pthread_mutex_unlock(&mechanism->lock);
    if (alreadyInvoked) {
        return MacPearlSetDenyOnce(mechanism);
    }
    if (mechanism->kind == MacPearlMechanismKindFaceUnlock) {
        os_log_info(MacPearlLog(), "FaceUnlock invoked; denying by design");
        return MacPearlSetDenyOnce(mechanism);
    }

    pthread_mutex_lock(&gProbeFunctionsLock);
    MacPearlCameraProbeFunctions functions = gProbeFunctions;
    pthread_mutex_unlock(&gProbeFunctionsLock);
    if (functions.create == NULL || functions.start == NULL || functions.cancel == NULL || functions.release == NULL) {
        return MacPearlSetDenyOnce(mechanism);
    }

    MacPearlMechanismRetain(mechanism);
    MacPearlCameraProbeRef probe = functions.create(MacPearlCameraProbeCompleted, mechanism);
    if (probe == NULL) {
        OSStatus status = MacPearlSetDenyOnce(mechanism);
        MacPearlMechanismRelease(mechanism);
        return status;
    }
    pthread_mutex_lock(&mechanism->lock);
    mechanism->cameraProbe = probe;
    mechanism->probeFunctions = functions;
    pthread_mutex_unlock(&mechanism->lock);
    os_log_info(MacPearlLog(), "CameraProbe invoked in diagnostic always-deny mode");
    functions.start(probe);
    return errAuthorizationSuccess;
}

static OSStatus MacPearlMechanismDeactivate(AuthorizationMechanismRef inMechanism)
{
    if (inMechanism == NULL) return errAuthorizationInternal;
    MacPearlMechanism *mechanism = (MacPearlMechanism *)inMechanism;
    MacPearlCameraProbeRef probe = NULL;
    MacPearlCameraProbeFunctions functions;
    bool shouldNotify = false;
    pthread_mutex_lock(&mechanism->lock);
    if (!mechanism->deactivated) {
        mechanism->deactivated = true;
        shouldNotify = true;
    }
    probe = mechanism->cameraProbe;
    mechanism->cameraProbe = NULL;
    functions = mechanism->probeFunctions;
    pthread_mutex_unlock(&mechanism->lock);
    if (probe != NULL) {
        functions.cancel(probe);
        functions.release(probe);
    }
    return shouldNotify ? mechanism->callbacks->DidDeactivate(mechanism->engine) : errAuthorizationSuccess;
}

static OSStatus MacPearlMechanismDestroy(AuthorizationMechanismRef inMechanism)
{
    if (inMechanism == NULL) return errAuthorizationInternal;
    MacPearlMechanism *mechanism = (MacPearlMechanism *)inMechanism;
    MacPearlCameraProbeRef probe = NULL;
    MacPearlCameraProbeFunctions functions;
    pthread_mutex_lock(&mechanism->lock);
    mechanism->destroyed = true;
    probe = mechanism->cameraProbe;
    mechanism->cameraProbe = NULL;
    functions = mechanism->probeFunctions;
    pthread_mutex_unlock(&mechanism->lock);
    if (probe != NULL) {
        functions.cancel(probe);
        functions.release(probe);
    }
    MacPearlMechanismRelease(mechanism);
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
    const AuthorizationCallbacks *callbacks, AuthorizationPluginRef *outPlugin,
    const AuthorizationPluginInterface **outPluginInterface)
{
    if (outPlugin != NULL) *outPlugin = NULL;
    if (outPluginInterface != NULL) *outPluginInterface = NULL;
    if (callbacks == NULL || outPlugin == NULL || outPluginInterface == NULL ||
        callbacks->SetResult == NULL || callbacks->DidDeactivate == NULL) return errAuthorizationInternal;
    MacPearlPlugin *plugin = calloc(1, sizeof(*plugin));
    if (plugin == NULL) return errAuthorizationInternal;
    plugin->callbacks = callbacks;
    *outPlugin = plugin;
    *outPluginInterface = &MacPearlPluginInterface;
    return errAuthorizationSuccess;
}

void MacPearlAuthorizationPluginSetCameraProbeFunctionsForTesting(
    const MacPearlCameraProbeFunctions *functions)
{
    pthread_mutex_lock(&gProbeFunctionsLock);
    if (functions == NULL) {
        gProbeFunctions = (MacPearlCameraProbeFunctions){
            .create = MacPearlBrokerProbeCreate, .start = MacPearlBrokerProbeStart,
            .cancel = MacPearlBrokerProbeCancel, .release = MacPearlBrokerProbeRelease,
        };
    } else {
        gProbeFunctions = *functions;
    }
    pthread_mutex_unlock(&gProbeFunctionsLock);
}
