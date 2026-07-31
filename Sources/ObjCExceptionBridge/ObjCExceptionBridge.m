#import "include/ObjCExceptionBridge.h"

NSErrorDomain const FTObjCExceptionErrorDomain = @"FTObjCExceptionErrorDomain";

BOOL FTRunCatchingObjCException(void (NS_NOESCAPE ^body)(void), NSError **error) {
    @try {
        body();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
            userInfo[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
            userInfo[@"FTExceptionName"] = exception.name;
            if (exception.reason) {
                userInfo[@"FTExceptionReason"] = exception.reason;
            }
            *error = [NSError errorWithDomain:FTObjCExceptionErrorDomain
                                         code:1
                                     userInfo:userInfo];
        }
        return NO;
    }
}
