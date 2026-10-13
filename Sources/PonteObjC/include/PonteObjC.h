#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and catches any Objective-C exception it raises. AVAudioEngine reports some
/// failures (installTap with a mismatched format, play on a stopped engine) by raising, which Swift
/// cannot catch and which aborts the app. Returns nil on success, otherwise the exception's reason.
NSString * _Nullable PonteCatchObjC(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
