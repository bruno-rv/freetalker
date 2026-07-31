#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const FTObjCExceptionErrorDomain;

/// Installs a tap on `node`, containing any `NSException` it raises and reporting it as an
/// `NSError` (domain `FTObjCExceptionErrorDomain`, `userInfo` carrying the exception name and
/// reason) instead.
///
/// Swift cannot catch an `NSException`. `-installTapOnBus:bufferSize:format:block:` is a void API
/// that raises one rather than returning an error, and FreeTalker observed exactly that: AppKit
/// caught the exception at the run-loop boundary, the process carried on, and it later segfaulted
/// inside an unrelated `MainActor` isolation check
/// (docs/dictation-zero-audio-crash-2026-07-31.md).
///
/// The call is made here, directly, rather than through a caller-supplied block: a block written
/// in Swift would put a Swift frame between the raise and this `@catch`, which is the situation
/// being avoided. `block` is only stored by the tap, never invoked during installation.
///
/// A caught exception leaves the engine in an unknown state. Callers must discard that engine
/// without calling anything else on it.
BOOL FTInstallTapCatchingException(AVAudioNode *node,
                                   AVAudioNodeBus bus,
                                   AVAudioFrameCount bufferSize,
                                   AVAudioFormat *_Nullable format,
                                   AVAudioNodeTapBlock block,
                                   NSError **error);

NS_ASSUME_NONNULL_END
