#import "MacPearlCameraProbe.h"

#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>

static const NSTimeInterval MacPearlCameraProbeTimeout = 2.0;

@interface MacPearlCameraProbe : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>

- (instancetype)initWithCompletion:(MacPearlCameraProbeCompletion)completion
                            context:(void *)context;
- (void)start;
- (void)cancel;

@end

@implementation MacPearlCameraProbe {
    MacPearlCameraProbeCompletion _completion;
    void *_context;
    dispatch_queue_t _sessionQueue;
    AVCaptureSession *_session;
    NSLock *_finishLock;
    BOOL _finished;
    CFAbsoluteTime _startedAt;
    MacPearlCameraProbeResult _result;
}

- (instancetype)initWithCompletion:(MacPearlCameraProbeCompletion)completion
                            context:(void *)context
{
    self = [super init];
    if (self) {
        _completion = completion;
        _context = context;
        _sessionQueue = dispatch_queue_create(
            "com.stevenha.MacPearl.AuthorizationPlugin.camera-probe",
            DISPATCH_QUEUE_SERIAL
        );
        _finishLock = [[NSLock alloc] init];
        memset(&_result, 0, sizeof(_result));
        _result.firstFrameLatencyMilliseconds = -1;
    }
    return self;
}

- (void)start
{
    dispatch_async(_sessionQueue, ^{
        [self startOnSessionQueue];
    });

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MacPearlCameraProbeTimeout * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
        ^{
            [self finishWithOutcome:MacPearlCameraProbeOutcomeTimedOut];
        }
    );
}

- (void)cancel
{
    [self finishWithOutcome:MacPearlCameraProbeOutcomeCancelled];
}

- (void)startOnSessionQueue
{
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    [_finishLock lock];
    _result.authorizationStatus = (int32_t)status;
    [_finishLock unlock];
    if (status != AVAuthorizationStatusAuthorized) {
        [self finishWithOutcome:MacPearlCameraProbeOutcomePermissionUnavailable];
        return;
    }

    AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:@[
            AVCaptureDeviceTypeBuiltInWideAngleCamera,
            AVCaptureDeviceTypeExternal,
            AVCaptureDeviceTypeContinuityCamera,
        ]
        mediaType:AVMediaTypeVideo
        position:AVCaptureDevicePositionUnspecified
    ];
    NSArray<AVCaptureDevice *> *devices = [discovery.devices filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(AVCaptureDevice *device, NSDictionary *bindings) {
            return device.connected && !device.suspended;
        }]
    ];
    [_finishLock lock];
    _result.deviceCount = (uint32_t)devices.count;
    [_finishLock unlock];

    AVCaptureDevice *device = [self preferredDeviceFromDevices:devices];
    if (device == nil) {
        [self finishWithOutcome:MacPearlCameraProbeOutcomeNoCamera];
        return;
    }

    [self recordMetadataForDevice:device];
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (input == nil || error != nil) {
        [self finishWithOutcome:MacPearlCameraProbeOutcomeConfigurationFailed];
        return;
    }

    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
    output.alwaysDiscardsLateVideoFrames = YES;
    [output setSampleBufferDelegate:self queue:_sessionQueue];

    [session beginConfiguration];
    if (![session canAddInput:input] || ![session canAddOutput:output]) {
        [session commitConfiguration];
        [self finishWithOutcome:MacPearlCameraProbeOutcomeConfigurationFailed];
        return;
    }
    [session addInput:input];
    [session addOutput:output];
    [session commitConfiguration];

    [_finishLock lock];
    BOOL alreadyFinished = _finished;
    if (!alreadyFinished) {
        _session = session;
        _startedAt = CFAbsoluteTimeGetCurrent();
    }
    [_finishLock unlock];
    if (alreadyFinished) {
        return;
    }

    [session startRunning];
}

- (AVCaptureDevice *)preferredDeviceFromDevices:(NSArray<AVCaptureDevice *> *)devices
{
    AVCaptureDevice *systemPreferred = AVCaptureDevice.systemPreferredCamera;
    if ([devices containsObject:systemPreferred]) {
        return systemPreferred;
    }
    AVCaptureDevice *userPreferred = AVCaptureDevice.userPreferredCamera;
    if ([devices containsObject:userPreferred]) {
        return userPreferred;
    }
    for (AVCaptureDevice *device in devices) {
        if ([device.deviceType isEqualToString:AVCaptureDeviceTypeExternal]) {
            return device;
        }
    }
    for (AVCaptureDevice *device in devices) {
        if ([device.deviceType isEqualToString:AVCaptureDeviceTypeContinuityCamera]) {
            return device;
        }
    }
    return devices.firstObject;
}

- (void)recordMetadataForDevice:(AVCaptureDevice *)device
{
    MacPearlCameraProbeResult metadata = {0};
    const char *deviceType = device.deviceType.UTF8String ?: "unknown";
    strlcpy(metadata.deviceType, deviceType, sizeof(metadata.deviceType));

    NSData *identifier = [device.uniqueID dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(identifier.bytes, (CC_LONG)identifier.length, digest);
    for (NSUInteger index = 0; index < 8; index += 1) {
        snprintf(
            &metadata.deviceIdentifierHash[index * 2],
            sizeof(metadata.deviceIdentifierHash) - (index * 2),
            "%02x",
            digest[index]
        );
    }
    [_finishLock lock];
    strlcpy(_result.deviceType, metadata.deviceType, sizeof(_result.deviceType));
    strlcpy(
        _result.deviceIdentifierHash,
        metadata.deviceIdentifierHash,
        sizeof(_result.deviceIdentifierHash)
    );
    [_finishLock unlock];
}

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    [_finishLock lock];
    _result.firstFrameLatencyMilliseconds =
        (CFAbsoluteTimeGetCurrent() - _startedAt) * 1000;
    [_finishLock unlock];
    [self finishWithOutcome:MacPearlCameraProbeOutcomeFrameReceived];
}

- (void)finishWithOutcome:(MacPearlCameraProbeOutcome)outcome
{
    __attribute__((objc_precise_lifetime)) MacPearlCameraProbe *keepAlive = self;
    [_finishLock lock];
    if (_finished) {
        [_finishLock unlock];
        return;
    }
    _finished = YES;
    _result.outcome = outcome;
    AVCaptureSession *session = _session;
    _session = nil;
    MacPearlCameraProbeCompletion completion = _completion;
    void *context = _context;
    MacPearlCameraProbeResult result = _result;
    [_finishLock unlock];

    if (session != nil) {
        dispatch_async(_sessionQueue, ^{
            if (session.running) {
                [session stopRunning];
            }
        });
    }
    if (completion != NULL) {
        completion(context, &result);
    }
    (void)keepAlive;
}

@end

MacPearlCameraProbeRef MacPearlCameraProbeCreate(
    MacPearlCameraProbeCompletion completion,
    void *context
)
{
    if (completion == NULL) {
        return NULL;
    }
    MacPearlCameraProbe *probe = [[MacPearlCameraProbe alloc]
        initWithCompletion:completion
        context:context
    ];
    return (__bridge_retained void *)probe;
}

void MacPearlCameraProbeStart(MacPearlCameraProbeRef probe)
{
    if (probe != NULL) {
        [(__bridge MacPearlCameraProbe *)probe start];
    }
}

void MacPearlCameraProbeCancel(MacPearlCameraProbeRef probe)
{
    if (probe != NULL) {
        [(__bridge MacPearlCameraProbe *)probe cancel];
    }
}

void MacPearlCameraProbeRelease(MacPearlCameraProbeRef probe)
{
    if (probe != NULL) {
        CFRelease(probe);
    }
}
