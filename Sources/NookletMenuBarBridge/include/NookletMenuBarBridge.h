#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL NookletMenuBarCanRestrict(void);
void NookletMenuBarRestrict(NSArray<NSString *> *allowedApps, BOOL showsInputMenu, void (^completion)(NSObject * _Nullable assertion, NSError * _Nullable error));
void NookletMenuBarRelease(NSObject *assertion);

NS_ASSUME_NONNULL_END
