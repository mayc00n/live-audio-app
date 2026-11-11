#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

// Capture-only RemoteIO device. It does not activate/configure AVAudioSession:
// AudioRouter owns that session and the chosen wired input for the entire run.
@interface WiredAudioDevice : NSObject <RTCAudioDevice>
@property(atomic) BOOL requireExternal;
@property(atomic) BOOL captureAllowed;
@property(atomic, copy) NSString *expectedInputUID;
@property(atomic, readonly) NSInteger lastError;
- (void)refreshRouteGate;
- (void)restartAfterRouteChange;
- (void)resumeAfterInterruption;
@end
