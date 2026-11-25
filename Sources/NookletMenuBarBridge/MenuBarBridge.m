#import "NookletMenuBarBridge.h"
#import <dispatch/dispatch.h>
#import <dlfcn.h>

// Runtime interface used by Hidden Bar's macOS 27 engine (dwarvesf/hidden).
// No preferences are written: the menu bar restores visibility when the assertion ends.
@protocol NookletMenuBarConfiguration
- (instancetype)initWithAllowedSystemItems:(NSArray<NSNumber *> *)items
                  allowedBundleIdentifiers:(NSArray<NSString *> *)apps;
@end

@protocol NookletMenuBarAssertion
- (void)activateWithConfiguration:(NSObject *)configuration completionHandler:(void (^)(NSError *))completion;
- (void)invalidate;
@end

static Class configurationClass;
static Class assertionClass;

BOOL NookletMenuBarCanRestrict(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_LAZY | RTLD_LOCAL)) {
            configurationClass = NSClassFromString(@"MBAssessmentModeConfiguration");
            assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");
        }
    });
    return [configurationClass instancesRespondToSelector:@selector(initWithAllowedSystemItems:allowedBundleIdentifiers:)]
        && [assertionClass instancesRespondToSelector:@selector(activateWithConfiguration:completionHandler:)]
        && [assertionClass instancesRespondToSelector:@selector(invalidate)];
}

static NSError *visibilityError(NSString *message) {
    return [NSError errorWithDomain:@"Nooklet.MenuBar" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

void NookletMenuBarRestrict(NSArray<NSString *> *allowedApps, BOOL showsInputMenu, void (^completion)(NSObject *, NSError *)) {
    if (!NookletMenuBarCanRestrict()) {
        completion(nil, visibilityError(@"当前系统不支持管理菜单栏可见性。"));
        return;
    }
    @try {
        NSMutableArray<NSNumber *> *systemItems = [NSMutableArray arrayWithCapacity:64];
        const NSInteger keyboardSystemItem = 4;
        for (NSInteger index = 0; index < 64; index++) {
            if (showsInputMenu || index != keyboardSystemItem) {
                [systemItems addObject:@(index)];
            }
        }
        id configuration = [(id<NookletMenuBarConfiguration>)[configurationClass alloc]
            initWithAllowedSystemItems:systemItems allowedBundleIdentifiers:allowedApps];
        NSObject<NookletMenuBarAssertion> *assertion = [[assertionClass alloc] init];
        if (!configuration || !assertion) {
            completion(nil, visibilityError(@"无法创建菜单栏可见性配置。"));
            return;
        }
        [assertion activateWithConfiguration:configuration completionHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(error == nil ? assertion : nil, error);
            });
        }];
#if !__has_feature(objc_arc)
        [configuration release];
        [assertion release];
#endif
    } @catch (NSException *exception) {
        completion(nil, visibilityError(exception.reason ?: @"无法应用菜单栏可见性设置。"));
    }
}

void NookletMenuBarRelease(NSObject *assertion) {
    @try {
        [(id<NookletMenuBarAssertion>)assertion invalidate];
    } @catch (NSException *exception) {
        NSLog(@"Nooklet menu bar visibility: %@", exception.reason);
    }
}
