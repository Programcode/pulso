#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, or nil.
/// HealthKit reports some misuse (a type the OS won't authorize, a unit
/// string it can't parse) by raising, which Swift cannot catch.
NSException *_Nullable PulsoCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
