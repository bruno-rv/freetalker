#import "include/ObjCExceptionBridge.h"

NSErrorDomain const FTObjCExceptionErrorDomain = @"FTObjCExceptionErrorDomain";

static NSError *FTErrorFromException(NSException *exception) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
    userInfo[@"FTExceptionName"] = exception.name;
    if (exception.reason) {
        userInfo[@"FTExceptionReason"] = exception.reason;
    }
    return [NSError errorWithDomain:FTObjCExceptionErrorDomain code:1 userInfo:userInfo];
}

BOOL FTInstallTapCatchingException(AVAudioNode *node,
                                   AVAudioNodeBus bus,
                                   AVAudioFrameCount bufferSize,
                                   AVAudioFormat *_Nullable format,
                                   AVAudioNodeTapBlock block,
                                   NSError **error) {
    @try {
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = FTErrorFromException(exception);
        }
        return NO;
    }
}
