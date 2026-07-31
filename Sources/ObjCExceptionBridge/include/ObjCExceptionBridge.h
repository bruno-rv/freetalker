#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const FTObjCExceptionErrorDomain;

/// Runs `body` inside an Objective-C `@try`/`@catch`, returning NO and populating `error` (domain
/// `FTObjCExceptionErrorDomain`, `userInfo` carrying the exception's name and reason) if it raised.
///
/// Swift cannot catch an `NSException`. Some AVAudioEngine graph calls — `installTap` above all —
/// are void APIs that raise one instead of returning an error, and letting that exception unwind
/// out through Swift frames leaves the process in an undefined state: AppKit catches it at the
/// run-loop boundary and execution continues, but the Swift frames in between were unwound without
/// running their cleanup. FreeTalker observed exactly that, and the process then segfaulted later
/// inside an unrelated `MainActor` isolation check
/// (docs/dictation-zero-audio-crash-2026-07-31.md). Containing the throw here keeps the unwind
/// inside Objective-C frames and hands Swift a plain `NSError`.
///
/// A caught exception still means the framework object is in an unknown state — callers must
/// discard the affected graph rather than keep using it.
BOOL FTRunCatchingObjCException(void (NS_NOESCAPE ^body)(void), NSError **error);

NS_ASSUME_NONNULL_END
