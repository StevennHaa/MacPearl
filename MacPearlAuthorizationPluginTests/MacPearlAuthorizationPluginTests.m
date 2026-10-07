#import <XCTest/XCTest.h>

#import "MacPearlAuthorizationPlugin.h"

typedef struct {
    AuthorizationResult lastResult;
    NSUInteger setResultCount;
    NSUInteger didDeactivateCount;
} FakeAuthorizationEngine;

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
