#import <XCTest/XCTest.h>

#import "MacPearlAuthorizationPlugin.h"

typedef struct {
    AuthorizationResult lastResult;
    NSUInteger setResultCount;
    NSUInteger didDeactivateCount;
} FakeAuthorizationEngine;

typedef struct {
    MacPearlCameraProbeCompletion completion;
    void *context;
} FakeCameraProbe;

static NSUInteger FakeProbeStartCount;
static NSUInteger FakeProbeCancelCount;
static NSUInteger FakeProbeReleaseCount;
static BOOL FakeProbeCompletesOnStart;

static MacPearlCameraProbeRef FakeProbeCreate(MacPearlCameraProbeCompletion completion, void *context)
{
    FakeCameraProbe *probe = calloc(1, sizeof(*probe));
    probe->completion = completion;
    probe->context = context;
    return probe;
}

static void FakeProbeStart(MacPearlCameraProbeRef reference)
{
    FakeProbeStartCount += 1;
    FakeCameraProbe *probe = reference;
    if (FakeProbeCompletesOnStart) {
        MacPearlCameraProbeResult result = {.outcome = MacPearlCameraProbeOutcomeFrameReceived};
        probe->completion(probe->context, &result);
    }
}

static void FakeProbeCancel(MacPearlCameraProbeRef reference)
{
    FakeProbeCancelCount += 1;
    FakeCameraProbe *probe = reference;
    MacPearlCameraProbeResult result = {.outcome = MacPearlCameraProbeOutcomeCancelled};
    probe->completion(probe->context, &result);
}

static void FakeProbeRelease(MacPearlCameraProbeRef reference)
{
    FakeProbeReleaseCount += 1;
    free(reference);
}

static OSStatus FakeSetResult(
    AuthorizationEngineRef engine,
    AuthorizationResult result
)
{
    FakeAuthorizationEngine *fake = (FakeAuthorizationEngine *)engine;
    fake->lastResult = result;
    fake->setResultCount += 1;
    return errAuthorizationSuccess;
}

static OSStatus FakeDidDeactivate(AuthorizationEngineRef engine)
{
    FakeAuthorizationEngine *fake = (FakeAuthorizationEngine *)engine;
    fake->didDeactivateCount += 1;
    return errAuthorizationSuccess;
}

@interface MacPearlAuthorizationPluginTests : XCTestCase
@end

@implementation MacPearlAuthorizationPluginTests

- (void)setUp
{
    [super setUp];
    FakeProbeStartCount = 0;
    FakeProbeCancelCount = 0;
    FakeProbeReleaseCount = 0;
    FakeProbeCompletesOnStart = NO;
    MacPearlCameraProbeFunctions functions = {
        .create = FakeProbeCreate,
        .start = FakeProbeStart,
        .cancel = FakeProbeCancel,
        .release = FakeProbeRelease,
    };
    MacPearlAuthorizationPluginSetCameraProbeFunctionsForTesting(&functions);
}

- (void)tearDown
{
    MacPearlAuthorizationPluginSetCameraProbeFunctionsForTesting(NULL);
    [super tearDown];
}

- (AuthorizationCallbacks)callbacks
{
    AuthorizationCallbacks callbacks = {0};
    callbacks.version = kAuthorizationCallbacksVersion;
    callbacks.SetResult = FakeSetResult;
    callbacks.DidDeactivate = FakeDidDeactivate;
    return callbacks;
}

- (void)testPluginPublishesExpectedInterface
{
    AuthorizationCallbacks callbacks = [self callbacks];
    AuthorizationPluginRef plugin = NULL;
    const AuthorizationPluginInterface *interface = NULL;

    XCTAssertEqual(
        AuthorizationPluginCreate(&callbacks, &plugin, &interface),
        errAuthorizationSuccess
    );
    XCTAssertNotEqual(plugin, NULL);
    XCTAssertNotEqual(interface, NULL);
    XCTAssertEqual(interface->version, kAuthorizationPluginInterfaceVersion);
    XCTAssertNotEqual(interface->MechanismCreate, NULL);
    XCTAssertNotEqual(interface->MechanismInvoke, NULL);
    XCTAssertNotEqual(interface->MechanismDeactivate, NULL);
    XCTAssertNotEqual(interface->MechanismDestroy, NULL);
    XCTAssertEqual(interface->PluginDestroy(plugin), errAuthorizationSuccess);
}

- (void)testFaceUnlockMechanismAlwaysDenies
{
    AuthorizationCallbacks callbacks = [self callbacks];
    AuthorizationPluginRef plugin = NULL;
    const AuthorizationPluginInterface *interface = NULL;
    XCTAssertEqual(
        AuthorizationPluginCreate(&callbacks, &plugin, &interface),
        errAuthorizationSuccess
    );

    FakeAuthorizationEngine fakeEngine = {0};
    AuthorizationMechanismRef mechanism = NULL;
    XCTAssertEqual(
        interface->MechanismCreate(
            plugin,
            (AuthorizationEngineRef)&fakeEngine,
            MACPEARL_FACE_UNLOCK_MECHANISM,
            &mechanism
        ),
        errAuthorizationSuccess
    );

    XCTAssertEqual(interface->MechanismInvoke(mechanism), errAuthorizationSuccess);
    XCTAssertEqual(fakeEngine.setResultCount, 1u);
    XCTAssertEqual(fakeEngine.lastResult, kAuthorizationResultDeny);

    XCTAssertEqual(interface->MechanismDeactivate(mechanism), errAuthorizationSuccess);
    XCTAssertEqual(fakeEngine.didDeactivateCount, 1u);

    XCTAssertEqual(interface->MechanismDestroy(mechanism), errAuthorizationSuccess);
    XCTAssertEqual(interface->PluginDestroy(plugin), errAuthorizationSuccess);
}

- (void)testUnknownMechanismFailsClosed
{
    AuthorizationCallbacks callbacks = [self callbacks];
    AuthorizationPluginRef plugin = NULL;
    const AuthorizationPluginInterface *interface = NULL;
    XCTAssertEqual(
        AuthorizationPluginCreate(&callbacks, &plugin, &interface),
        errAuthorizationSuccess
    );

    FakeAuthorizationEngine fakeEngine = {0};
    AuthorizationMechanismRef mechanism = (AuthorizationMechanismRef)0x1;
    XCTAssertEqual(
        interface->MechanismCreate(
            plugin,
            (AuthorizationEngineRef)&fakeEngine,
            "UnknownMechanism",
            &mechanism
        ),
        errAuthorizationInternal
    );
    XCTAssertEqual(mechanism, NULL);
    XCTAssertEqual(fakeEngine.setResultCount, 0u);
    XCTAssertEqual(interface->PluginDestroy(plugin), errAuthorizationSuccess);
}

- (void)testCameraProbeAlwaysDeniesAfterReceivingAFrame
{
    FakeProbeCompletesOnStart = YES;
    AuthorizationCallbacks callbacks = [self callbacks];
    AuthorizationPluginRef plugin = NULL;
    const AuthorizationPluginInterface *interface = NULL;
    XCTAssertEqual(AuthorizationPluginCreate(&callbacks, &plugin, &interface), errAuthorizationSuccess);
    FakeAuthorizationEngine engine = {0};
    AuthorizationMechanismRef mechanism = NULL;
    XCTAssertEqual(interface->MechanismCreate(plugin, (AuthorizationEngineRef)&engine, MACPEARL_CAMERA_PROBE_MECHANISM, &mechanism), errAuthorizationSuccess);
    XCTAssertEqual(interface->MechanismInvoke(mechanism), errAuthorizationSuccess);
    XCTAssertEqual(interface->MechanismInvoke(mechanism), errAuthorizationSuccess);
    XCTAssertEqual(FakeProbeStartCount, 1u);
    XCTAssertEqual(FakeProbeReleaseCount, 1u);
    XCTAssertEqual(engine.setResultCount, 1u);
    XCTAssertEqual(engine.lastResult, kAuthorizationResultDeny);
    XCTAssertEqual(interface->MechanismDestroy(mechanism), errAuthorizationSuccess);
    XCTAssertEqual(interface->PluginDestroy(plugin), errAuthorizationSuccess);
}

- (void)testCameraProbeCancellationDeniesAndDeactivatesOnce
{
    AuthorizationCallbacks callbacks = [self callbacks];
    AuthorizationPluginRef plugin = NULL;
    const AuthorizationPluginInterface *interface = NULL;
    XCTAssertEqual(AuthorizationPluginCreate(&callbacks, &plugin, &interface), errAuthorizationSuccess);
    FakeAuthorizationEngine engine = {0};
    AuthorizationMechanismRef mechanism = NULL;
    XCTAssertEqual(interface->MechanismCreate(plugin, (AuthorizationEngineRef)&engine, MACPEARL_CAMERA_PROBE_MECHANISM, &mechanism), errAuthorizationSuccess);
    XCTAssertEqual(interface->MechanismInvoke(mechanism), errAuthorizationSuccess);
    XCTAssertEqual(interface->MechanismDeactivate(mechanism), errAuthorizationSuccess);
    XCTAssertEqual(interface->MechanismDeactivate(mechanism), errAuthorizationSuccess);
    XCTAssertEqual(FakeProbeCancelCount, 1u);
    XCTAssertEqual(FakeProbeReleaseCount, 1u);
    XCTAssertEqual(engine.setResultCount, 1u);
    XCTAssertEqual(engine.didDeactivateCount, 1u);
    XCTAssertEqual(interface->MechanismDestroy(mechanism), errAuthorizationSuccess);
    XCTAssertEqual(interface->PluginDestroy(plugin), errAuthorizationSuccess);
}

- (void)testMissingRequiredCallbackRejectsPlugin
{
    AuthorizationCallbacks callbacks = [self callbacks];
    callbacks.SetResult = NULL;
    AuthorizationPluginRef plugin = (AuthorizationPluginRef)0x1;
    const AuthorizationPluginInterface *interface =
        (const AuthorizationPluginInterface *)0x1;

    XCTAssertEqual(
        AuthorizationPluginCreate(&callbacks, &plugin, &interface),
        errAuthorizationInternal
    );
    XCTAssertEqual(plugin, NULL);
    XCTAssertEqual(interface, NULL);
}

@end
