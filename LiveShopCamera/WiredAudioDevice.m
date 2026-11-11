#import "WiredAudioDevice.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

static const UInt32 MaxCaptureFrames = 4096;
static const double CaptureRate = 48000;

@interface WiredAudioDevice () {
    AudioUnit _unit;
    int16_t *_samples;
    id _routeObserver;
    NSString *_captureRoute;
}
@property(nonatomic, strong) id<RTCAudioDeviceDelegate> audioDelegate;
@property(atomic, readwrite) BOOL isInitialized;
@property(atomic, readwrite) BOOL isRecordingInitialized;
@property(atomic, readwrite) BOOL isPlayoutInitialized;
@property(atomic, readwrite) BOOL isRecording;
@property(atomic, readwrite) BOOL isPlaying;
@property(atomic, readwrite) NSInteger lastError;
- (OSStatus)captureWithFlags:(AudioUnitRenderActionFlags *)flags timestamp:(const AudioTimeStamp *)timestamp frames:(UInt32)frames;
@end

@implementation WiredAudioDevice
- (instancetype)init {
    if ((self = [super init])) {
        _requireExternal = YES;
        _expectedInputUID = @"";
        _samples = calloc(MaxCaptureFrames, sizeof(int16_t));
        __weak WiredAudioDevice *weakSelf = self;
        // Close the gate synchronously on the notification thread, before UI work.
        _routeObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:nil
            usingBlock:^(NSNotification *note) { [weakSelf refreshRouteGate]; }];
    }
    return self;
}
- (void)dealloc {
    if (_routeObserver) [[NSNotificationCenter defaultCenter] removeObserver:_routeObserver];
    [self disposeUnit];
    free(_samples);
}
- (void)refreshRouteGate {
    NSArray<AVAudioSessionPortDescription *> *inputs = AVAudioSession.sharedInstance.currentRoute.inputs;
    NSString *expected = self.expectedInputUID;
    BOOL allowed = inputs.count > 0;
    for (AVAudioSessionPortDescription *input in inputs) {
        BOOL external = [@[AVAudioSessionPortUSBAudio, AVAudioSessionPortHeadsetMic,
                              AVAudioSessionPortLineIn] containsObject:input.portType];
        if ((self.requireExternal && !external) ||
            (expected.length && ![input.UID isEqualToString:expected])) allowed = NO;
    }
    self.captureAllowed = allowed;
}
- (double)deviceInputSampleRate { return CaptureRate; }
- (double)deviceOutputSampleRate { return CaptureRate; }
- (NSTimeInterval)inputIOBufferDuration { return AVAudioSession.sharedInstance.IOBufferDuration ?: 0.01; }
- (NSTimeInterval)outputIOBufferDuration { return 0.01; }
- (NSInteger)inputNumberOfChannels { return 1; }
- (NSInteger)outputNumberOfChannels { return 1; }
- (NSTimeInterval)inputLatency { return AVAudioSession.sharedInstance.inputLatency; }
- (NSTimeInterval)outputLatency { return 0; }
- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
    self.audioDelegate = delegate; self.isInitialized = YES; return YES;
}
- (BOOL)terminateDevice {
    [self stopRecording]; self.audioDelegate = nil; self.isInitialized = NO;
    self.isRecordingInitialized = NO; self.isPlayoutInitialized = NO; return YES;
}
// The app only sends audio. Never open a speaker or change to a call audio unit.
- (BOOL)initializePlayout { self.isPlayoutInitialized = YES; return YES; }
- (BOOL)startPlayout { self.isPlaying = YES; return YES; }
- (BOOL)stopPlayout { self.isPlaying = NO; return YES; }
- (BOOL)initializeRecording { self.isRecordingInitialized = YES; return YES; }

static OSStatus CaptureInput(void *context, AudioUnitRenderActionFlags *flags,
                            const AudioTimeStamp *timestamp, UInt32 bus,
                            UInt32 frames, AudioBufferList *unused) {
    return [(__bridge WiredAudioDevice *)context captureWithFlags:flags timestamp:timestamp frames:frames];
}
- (OSStatus)captureWithFlags:(AudioUnitRenderActionFlags *)flags timestamp:(const AudioTimeStamp *)timestamp frames:(UInt32)frames {
    if (frames > MaxCaptureFrames) return kAudioUnitErr_TooManyFramesToProcess;
    AudioBufferList data = { .mNumberBuffers = 1,
        .mBuffers = {{ .mNumberChannels = 1, .mDataByteSize = frames * sizeof(int16_t),
                       .mData = _samples }} };
    OSStatus result = AudioUnitRender(_unit, flags, timestamp, 1, frames, &data);
    if (result != noErr) { self.lastError = result; return result; }
    // Keep the stream clock running with silence while its chosen input is lost.
    if (!self.captureAllowed) memset(_samples, 0, frames * sizeof(int16_t));
    id<RTCAudioDeviceDelegate> delegate = self.audioDelegate;
    if (!self.isRecording || !delegate) return noErr;
    return delegate.deliverRecordedData(flags, timestamp, 1, frames, &data, NULL, nil);
}
- (BOOL)createUnit {
    AudioComponentDescription description = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_RemoteIO,
        .componentManufacturer = kAudioUnitManufacturer_Apple
    };
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    OSStatus result = component ? AudioComponentInstanceNew(component, &_unit) : kAudio_ParamError;
    if (result != noErr) { self.lastError = result; return NO; }
    UInt32 on = 1, off = 0, maximum = MaxCaptureFrames;
    AudioStreamBasicDescription format = {
        .mSampleRate = CaptureRate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 2, .mFramesPerPacket = 1, .mBytesPerFrame = 2,
        .mChannelsPerFrame = 1, .mBitsPerChannel = 16
    };
    AURenderCallbackStruct callback = { .inputProc = CaptureInput, .inputProcRefCon = (__bridge void *)self };
    if ((result = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, sizeof(on))) == noErr &&
        (result = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, sizeof(off))) == noErr &&
        (result = AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, sizeof(format))) == noErr &&
        (result = AudioUnitSetProperty(_unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum, sizeof(maximum))) == noErr &&
        (result = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &callback, sizeof(callback))) == noErr) {
        result = AudioUnitInitialize(_unit);
    }
    if (result != noErr) { self.lastError = result; [self disposeUnit]; return NO; }
    self.lastError = 0; return YES;
}
- (void)disposeUnit {
    if (!_unit) return;
    AudioOutputUnitStop(_unit); AudioUnitUninitialize(_unit);
    AudioComponentInstanceDispose(_unit); _unit = NULL;
}
- (BOOL)startRecording {
    if (self.isRecording) return YES;
    if (!_samples || (![self createUnit])) return NO;
    [self refreshRouteGate];
    _captureRoute = [self routeSignature];
    [self.audioDelegate notifyAudioInputParametersChange];
    self.isRecording = YES;
    OSStatus result = AudioOutputUnitStart(_unit);
    if (result != noErr) {
        self.lastError = result; self.isRecording = NO; [self disposeUnit]; return NO;
    }
    return YES;
}
- (BOOL)stopRecording {
    self.isRecording = NO; self.captureAllowed = NO; [self disposeUnit]; return YES;
}
- (NSString *)routeSignature {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSMutableArray<NSString *> *ports = [NSMutableArray array];
    for (AVAudioSessionPortDescription *port in session.currentRoute.inputs) [ports addObject:port.UID];
    return [NSString stringWithFormat:@"%@|%.0f|%ld", [ports componentsJoinedByString:@","],
            session.sampleRate, (long)session.inputNumberOfChannels];
}
- (void)restartAfterRouteChange {
    id<RTCAudioDeviceDelegate> delegate = self.audioDelegate;
    if (!delegate) return;
    __weak WiredAudioDevice *weakSelf = self;
    [delegate dispatchAsync:^{
        WiredAudioDevice *device = weakSelf;
        if (!device || !device.isRecording) return;
        if ([device->_captureRoute isEqualToString:[device routeSignature]]) return;
        // All AudioUnit lifecycle operations stay on the ADM owning thread.
        [device stopRecording];
        [delegate notifyAudioInputInterrupted];
        [device startRecording];
    }];
}
@end
