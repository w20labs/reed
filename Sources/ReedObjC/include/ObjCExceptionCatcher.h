#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift cannot catch Obj-C NSExceptions, and AVAudioEngine raises them for
/// conditions that are inherently racy from the caller's side (installTap on
/// a node whose device is mid-switch, a stale node after a configuration
/// change). This shim runs a block under @try and returns the exception
/// instead of letting it abort the process.
@interface ObjCExceptionCatcher : NSObject
+ (nullable NSException *)catchException:(void (NS_NOESCAPE ^)(void))block;
@end

NS_ASSUME_NONNULL_END
