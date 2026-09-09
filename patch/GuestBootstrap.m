#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kGuestService = @"com.xd.mbp31.persistent-guest";
static NSString *const kGuestAccount = @"install-id";
static NSString *const kGuestDefaultsKey = @"MBPStableGuestInstallID";

static const void *kOrigDidLoadKey = &kOrigDidLoadKey;
static const void *kOrigWillAppearKey = &kOrigWillAppearKey;
static const void *kOrigDidAppearKey = &kOrigDidAppearKey;
static BOOL gInstalledMainRoot = NO;

static NSDictionary *MBPKeychainIdentityQuery(void) {
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kGuestService,
        (__bridge id)kSecAttrAccount: kGuestAccount
    };
}

static NSString *MBPStableInstallID(void) {
    NSMutableDictionary *query = [MBPKeychainIdentityQuery() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess && result) {
        NSData *data = CFBridgingRelease(result);
        NSString *existing = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (existing.length > 0) {
            [[NSUserDefaults standardUserDefaults] setObject:existing forKey:kGuestDefaultsKey];
            return existing;
        }
    } else if (result) {
        CFRelease(result);
    }

    NSString *generated = NSUUID.UUID.UUIDString.lowercaseString;
    NSData *data = [generated dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *item = [MBPKeychainIdentityQuery() mutableCopy];
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    item[(__bridge id)kSecValueData] = data;

    SecItemDelete((__bridge CFDictionaryRef)MBPKeychainIdentityQuery());
    OSStatus addStatus = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    if (addStatus != errSecSuccess && addStatus != errSecDuplicateItem) {
        NSLog(@"[MBPGuestBootstrap] Keychain save failed: %d", (int)addStatus);
    }

    [[NSUserDefaults standardUserDefaults] setObject:generated forKey:kGuestDefaultsKey];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"MBPPersistentGuestEnabled"];
    return generated;
}

static BOOL MBPIsMovieBoxLoginController(id object) {
    if (!object) return NO;
    NSString *name = NSStringFromClass([object class]);
    if (!name.length) return NO;
    return [name containsString:@"MBLoginBaseViewController"] ||
           [name containsString:@"MBCodeLoginViewController"] ||
           [name containsString:@"MBInvitationCodeLoginController"] ||
           [name containsString:@"TVCodeLoginController"];
}

static NSValue *MBPFindOriginalValue(Class cls, const void *key) {
    for (Class current = cls; current != Nil; current = class_getSuperclass(current)) {
        NSValue *value = objc_getAssociatedObject((id)current, key);
        if (value) return value;
    }
    return nil;
}

static IMP MBPOriginalIMP(id self, const void *key) {
    NSValue *value = MBPFindOriginalValue([self class], key);
    return value ? [value pointerValue] : NULL;
}

static Class MBPFindClass(NSArray<NSString *> *names) {
    for (NSString *name in names) {
        Class cls = NSClassFromString(name);
        if (!cls) cls = objc_getClass(name.UTF8String);
        if (cls) return cls;
    }
    return Nil;
}

static UIWindow *MBPWindowForController(UIViewController *vc) {
    UIWindow *window = vc.viewIfLoaded.window;
    if (window) return window;
    window = vc.navigationController.viewIfLoaded.window;
    if (window) return window;
    window = vc.presentingViewController.viewIfLoaded.window;
    if (window) return window;
    return nil;
}

static UIViewController *MBPCreateMainController(void) {
    Class cls = MBPFindClass(@[
        @"GoogleAdsSDK.MBTabBarController",
        @"_TtC12GoogleAdsSDK18MBTabBarController",
        @"MBTabBarController"
    ]);
    if (!cls) {
        NSLog(@"[MBPGuestBootstrap] MBTabBarController class not found");
        return nil;
    }

    id obj = ((id (*)(id, SEL))objc_msgSend)((id)cls, @selector(alloc));
    obj = ((id (*)(id, SEL))objc_msgSend)(obj, @selector(init));
    if (![obj isKindOfClass:UIViewController.class]) {
        NSLog(@"[MBPGuestBootstrap] MBTabBarController init failed");
        return nil;
    }
    return (UIViewController *)obj;
}

static void MBPDismissSecondaryLogin(UIViewController *vc) {
    if (!vc) return;
    if (vc.presentingViewController) {
        [vc.presentingViewController dismissViewControllerAnimated:NO completion:nil];
        return;
    }
    UINavigationController *nav = vc.navigationController;
    if (nav && nav.topViewController == vc && nav.viewControllers.count > 1) {
        [nav popViewControllerAnimated:NO];
    }
}

static void MBPRouteFromLogin(UIViewController *loginVC, NSInteger attempt) {
    if (!loginVC || !MBPIsMovieBoxLoginController(loginVC)) return;
    MBPStableInstallID();

    if (gInstalledMainRoot) {
        MBPDismissSecondaryLogin(loginVC);
        return;
    }

    UIWindow *window = MBPWindowForController(loginVC);
    if (!window) {
        if (attempt < 25) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                MBPRouteFromLogin(loginVC, attempt + 1);
            });
        }
        return;
    }

    UIViewController *main = MBPCreateMainController();
    if (!main) return;

    gInstalledMainRoot = YES;
    [UIView performWithoutAnimation:^{
        window.rootViewController = main;
        [window makeKeyAndVisible];
        [window layoutIfNeeded];
    }];
    NSLog(@"[MBPGuestBootstrap] Installed MBTabBarController as main root");
}

static void MBPLoginDidLoad(id self, SEL _cmd) {
    IMP original = MBPOriginalIMP(self, kOrigDidLoadKey);
    if (original && original != (IMP)MBPLoginDidLoad) {
        ((void (*)(id, SEL))original)(self, _cmd);
    }
    MBPStableInstallID();
}

static void MBPLoginWillAppear(id self, SEL _cmd, BOOL animated) {
    IMP original = MBPOriginalIMP(self, kOrigWillAppearKey);
    if (original && original != (IMP)MBPLoginWillAppear) {
        ((void (*)(id, SEL, BOOL))original)(self, _cmd, animated);
    }
    MBPStableInstallID();
}

static void MBPLoginDidAppear(id self, SEL _cmd, BOOL animated) {
    IMP original = MBPOriginalIMP(self, kOrigDidAppearKey);
    if (original && original != (IMP)MBPLoginDidAppear) {
        ((void (*)(id, SEL, BOOL))original)(self, _cmd, animated);
    }

    if ([self isKindOfClass:UIViewController.class]) {
        UIViewController *vc = (UIViewController *)self;
        dispatch_async(dispatch_get_main_queue(), ^{
            MBPRouteFromLogin(vc, 0);
        });
    }
}

static BOOL MBPInstallIsolatedHook(Class cls, SEL selector, IMP replacement, const void *key) {
    if (!cls) return NO;
    if (objc_getAssociatedObject((id)cls, key)) return YES;

    Method inherited = class_getInstanceMethod(cls, selector);
    if (!inherited) return NO;

    IMP original = method_getImplementation(inherited);
    const char *types = method_getTypeEncoding(inherited);
    if (!original || !types) return NO;

    if (!class_addMethod(cls, selector, replacement, types)) {
        Method own = class_getInstanceMethod(cls, selector);
        if (!own) return NO;
        original = method_getImplementation(own);
        if (original == replacement) return YES;
        method_setImplementation(own, replacement);
    }

    objc_setAssociatedObject((id)cls, key, [NSValue valueWithPointer:original], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

static BOOL MBPHookLoginClasses(void) {
    NSArray<NSArray<NSString *> *> *groups = @[
        @[@"GoogleAdsSDK.MBLoginBaseViewController", @"_TtC12GoogleAdsSDK25MBLoginBaseViewController", @"MBLoginBaseViewController"],
        @[@"GoogleAdsSDK.MBCodeLoginViewController", @"_TtC12GoogleAdsSDK25MBCodeLoginViewController", @"MBCodeLoginViewController"],
        @[@"GoogleAdsSDK.MBInvitationCodeLoginController", @"_TtC12GoogleAdsSDK31MBInvitationCodeLoginController", @"MBInvitationCodeLoginController"],
        @[@"GoogleAdsSDK.TVCodeLoginController", @"_TtC12GoogleAdsSDK21TVCodeLoginController", @"TVCodeLoginController"]
    ];

    BOOL foundAny = NO;
    for (NSArray<NSString *> *names in groups) {
        Class cls = MBPFindClass(names);
        if (!cls) continue;
        foundAny = YES;
        MBPInstallIsolatedHook(cls, @selector(viewDidLoad), (IMP)MBPLoginDidLoad, kOrigDidLoadKey);
        MBPInstallIsolatedHook(cls, @selector(viewWillAppear:), (IMP)MBPLoginWillAppear, kOrigWillAppearKey);
        MBPInstallIsolatedHook(cls, @selector(viewDidAppear:), (IMP)MBPLoginDidAppear, kOrigDidAppearKey);
    }
    return foundAny;
}

static void MBPInstallHooksWhenSafe(void) {
    MBPStableInstallID();
    if (MBPHookLoginClasses()) return;

    __block NSInteger attempts = 0;
    __block void (^retry)(void) = nil;
    retry = ^{
        attempts++;
        if (MBPHookLoginClasses() || attempts >= 100) {
            retry = nil;
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), retry);
    };
    retry();
}

__attribute__((constructor))
static void MBPGuestBootstrapInit(void) {
    @autoreleasepool {
        MBPStableInstallID();
        dispatch_async(dispatch_get_main_queue(), ^{
            MBPInstallHooksWhenSafe();
        });
    }
}
