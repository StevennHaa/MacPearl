#import "MacPearlBrokerProbe.h"

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <Security/SecRandom.h>
#include <math.h>
#include <string.h>

@protocol MacPearlCameraBrokerProtocol
- (void)healthWithReply:(void (^)(NSDictionary *))reply;
- (void)beginLockedScreenProbeWithNonce:(NSData *)nonce
                                  reply:(void (^)(NSDictionary *))reply;
- (void)cancelProbeWithNonce:(NSData *)nonce;
@end

@interface MacPearlBrokerProbe : NSObject
- (instancetype)initWithCompletion:(MacPearlCameraProbeCompletion)completion context:(void *)context;
- (void)start;
- (void)cancel;
@end

@implementation MacPearlBrokerProbe {
    MacPearlCameraProbeCompletion _completion;
    void *_context;
    NSLock *_lock;
    NSXPCConnection *_connection;
    NSData *_nonce;
    BOOL _finished;
}

static os_log_t MacPearlBrokerLog(void)
{
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.stevenha.MacPearl.AuthorizationPlugin", "broker");
    });
    return log;
}

- (instancetype)initWithCompletion:(MacPearlCameraProbeCompletion)completion context:(void *)context
{
    self = [super init];
    if (self) {
        _completion = completion;
        _context = context;
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (void)start
{
    NSXPCConnection *connection = [[NSXPCConnection alloc]
        initWithMachServiceName:@"com.stevenha.MacPearl.CameraBroker"
        options:0];
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(MacPearlCameraBrokerProtocol)];
    [connection setCodeSigningRequirement:
        @"anchor apple generic and identifier \"com.stevenha.MacPearl.CameraBroker\" and certificate leaf[subject.OU] = \"FY4JUG23QT\""];
    __weak MacPearlBrokerProbe *weakSelf = self;
    connection.interruptionHandler = ^{
        os_log_error(MacPearlBrokerLog(), "Broker XPC connection interrupted");
        [weakSelf finishWithOutcome:MacPearlCameraProbeOutcomeConfigurationFailed response:nil];
    };
    connection.invalidationHandler = ^{
        os_log_error(MacPearlBrokerLog(), "Broker XPC connection invalidated");
        [weakSelf finishWithOutcome:MacPearlCameraProbeOutcomeConfigurationFailed response:nil];
    };
    _connection = connection;

    NSMutableData *nonce = [NSMutableData dataWithLength:32];
    if (SecRandomCopyBytes(kSecRandomDefault, nonce.length, nonce.mutableBytes) != errSecSuccess) {
        [self finishWithOutcome:MacPearlCameraProbeOutcomeConfigurationFailed response:nil];
        return;
    }
    _nonce = nonce;
    [connection activate];
    id<MacPearlCameraBrokerProtocol> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
        os_log_error(MacPearlBrokerLog(), "Broker XPC request failed: %{public}@", proxyError);
        [weakSelf finishWithOutcome:MacPearlCameraProbeOutcomeConfigurationFailed response:nil];
    }];
    [proxy beginLockedScreenProbeWithNonce:nonce reply:^(NSDictionary *response) {
        [weakSelf handleResponse:response];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [weakSelf finishWithOutcome:MacPearlCameraProbeOutcomeTimedOut response:nil];
    });
}

- (void)cancel
{
    id<MacPearlCameraBrokerProtocol> proxy = [_connection remoteObjectProxy];
    if (_nonce != nil) [proxy cancelProbeWithNonce:_nonce];
    [self finishWithOutcome:MacPearlCameraProbeOutcomeCancelled response:nil];
}

- (void)handleResponse:(NSDictionary *)response
{
    NSNumber *version = response[@"version"];
    NSData *nonce = response[@"nonce"];
    NSNumber *generatedAt = response[@"generatedAt"];
    NSNumber *outcome = response[@"outcome"];
    if (![version isKindOfClass:NSNumber.class] || version.integerValue != 1 ||
        ![nonce isKindOfClass:NSData.class] || ![nonce isEqual:_nonce] ||
        ![generatedAt isKindOfClass:NSNumber.class] ||
        fabs(NSDate.date.timeIntervalSince1970 - generatedAt.doubleValue) > 3 ||
        ![outcome isKindOfClass:NSNumber.class]) {
        os_log_error(MacPearlBrokerLog(), "Broker response validation failed");
        [self finishWithOutcome:MacPearlCameraProbeOutcomeConfigurationFailed response:nil];
        return;
    }
    MacPearlCameraProbeOutcome mapped = MacPearlCameraProbeOutcomeConfigurationFailed;
    NSInteger value = outcome.integerValue;
    if (value >= 0 && value <= MacPearlCameraProbeOutcomeCancelled) {
        mapped = (MacPearlCameraProbeOutcome)value;
    } else if (value == 6) {
        mapped = MacPearlCameraProbeOutcomeTimedOut;
    }
    [self finishWithOutcome:mapped response:response];
}

- (void)finishWithOutcome:(MacPearlCameraProbeOutcome)outcome response:(NSDictionary *)response
{
    __attribute__((objc_precise_lifetime)) MacPearlBrokerProbe *keepAlive = self;
    [_lock lock];
    if (_finished) { [_lock unlock]; return; }
    _finished = YES;
    MacPearlCameraProbeCompletion completion = _completion;
    void *context = _context;
    NSXPCConnection *connection = _connection;
    _connection = nil;
    [_lock unlock];

    MacPearlCameraProbeResult result = {0};
    result.outcome = outcome;
    result.firstFrameLatencyMilliseconds = -1;
    if (response != nil) {
        result.authorizationStatus = [response[@"authorizationStatus"] intValue];
        result.deviceCount = [response[@"deviceCount"] unsignedIntValue];
        result.firstFrameLatencyMilliseconds = [response[@"latencyMilliseconds"] doubleValue];
        strlcpy(result.deviceType, [response[@"deviceType"] UTF8String] ?: "", sizeof(result.deviceType));
        strlcpy(result.deviceIdentifierHash, [response[@"deviceHash"] UTF8String] ?: "", sizeof(result.deviceIdentifierHash));
    }
    if (completion != NULL) completion(context, &result);
    [connection invalidate];
    (void)keepAlive;
}

@end

MacPearlCameraProbeRef MacPearlBrokerProbeCreate(MacPearlCameraProbeCompletion completion, void *context)
{
    if (completion == NULL) return NULL;
    return (__bridge_retained void *)[[MacPearlBrokerProbe alloc] initWithCompletion:completion context:context];
}
void MacPearlBrokerProbeStart(MacPearlCameraProbeRef probe) { [(__bridge MacPearlBrokerProbe *)probe start]; }
void MacPearlBrokerProbeCancel(MacPearlCameraProbeRef probe) { [(__bridge MacPearlBrokerProbe *)probe cancel]; }
void MacPearlBrokerProbeRelease(MacPearlCameraProbeRef probe) { if (probe != NULL) CFRelease(probe); }
