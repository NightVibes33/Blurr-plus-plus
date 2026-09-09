#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kGuestService = @"com.xd.mbp31.persistent-guest";
static NSString *const kGuestAccount = @"install-id";
static NSString *const kGuestDefaultsKey = @"MBPStableGuestInstallID";

static IMP gPresentIMP = NULL;
static IMP gPushIMP = NULL;

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

static BOOL MBPIsMovieBoxLoginController(id controller) {
    if (!controller) return NO;
    NSString *name = NSStringFromClass([controller class]);
    if (!name.length) return NO;

    static NSArray<NSString *> *blocked;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        blocked = @[
            @"MBLoginBaseViewController",
            @"MBCodeLoginViewController",
            @"MBInvitationCodeLoginController",
            @"TVCodeLoginController"
        ];
    });

    for (NSString *needle in blocked) {
        if ([name containsString:needle]) return YES;
    }
    return NO;
}

static void MBPDismissLoginController(UIViewController *vc) {
    if (!vc || !MBPIsMovieBoxLoginController(vc)) return;
    MBPStableInstallID();
    vc.view.hidden = YES;
    vc.view.userInteractionEnabled = NO;

    SEL close = NSSelectorFromString(@"close");
    SEL closeController = NSSelectorFromString(@"closeContrller");
    if ([vc respondsToSelector:close]) {
        ((void (*)(id, SEL))objc_msgSend)(vc, close);
        return;
    }
    if ([vc respondsToSelector:closeController]) {
        ((void (*)(id, SEL))objc_msgSend)(vc, closeController);
        return;
    }

    if (vc.presentingViewController) {
        [vc.presentingViewController dismissViewControllerAnimated:NO completion:nil];
        return;
    }

    UINavigationController *nav = vc.navigationController;
    if (nav && nav.topViewController == vc && nav.viewControllers.count > 1) {
        [nav popViewControllerAnimated:NO];
    }
}

static UIViewController *MBPTopController(UIViewController *vc) {
    if (!vc) return nil;
    if (vc.presentedViewController) return MBPTopController(vc.presentedViewController);
    if ([vc isKindOfClass:UINavigationController.class]) {
        return MBPTopController(((UINavigationController *)vc).visibleViewController);
    }
    if ([vc isKindOfClass:UITabBarController.class]) {
        return MBPTopController(((UITabBarController *)vc).selectedViewController);
    }
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *top = MBPTopController(child);
        if (top && top != child) return top;
        if (MBPIsMovieBoxLoginController(child)) return child;
    }
    return vc;
}

static void MBPSweepVisibleLogin(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            UIViewController *top = MBPTopController(window.rootViewController);
            if (MBPIsMovieBoxLoginController(top)) MBPDismissLoginController(top);
        }
    }
}

static void MBPPresentReplacement(id self, SEL _cmd, UIViewController *controller, BOOL animated, void (^completion)(void)) {
    if (MBPIsMovieBoxLoginController(controller)) {
        MBPStableInstallID();
        if (completion) completion();
        return;
    }
    if (gPresentIMP) {
        ((void (*)(id, SEL, UIViewController *, BOOL, void (^)(void)))gPresentIMP)(self, _cmd, controller, animated, completion);
    }
}

static void MBPPushReplacement(id self, SEL _cmd, UIViewController *controller, BOOL animated) {
    if (MBPIsMovieBoxLoginController(controller)) {
        MBPStableInstallID();
        return;
    }
    if (gPushIMP) {
        ((void (*)(id, SEL, UIViewController *, BOOL))gPushIMP)(self, _cmd, controller, animated);
    }
}

static BOOL MBPFalseBool(id self, SEL _cmd) {
    return NO;
}

static void MBPLoginViewDidLoad(id self, SEL _cmd) {
    MBPStableInstallID();
    if ([self isKindOfClass:UIViewController.class]) {
        UIViewController *vc = (UIViewController *)self;
        vc.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
        vc.view.hidden = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ MBPDismissLoginController(vc); });
    }
}

static void MBPLoginViewDidAppear(id self, SEL _cmd, BOOL animated) {
    MBPStableInstallID();
    if ([self isKindOfClass:UIViewController.class]) {
        MBPDismissLoginController((UIViewController *)self);
    }
}

static Class MBPFindClass(NSArray<NSString *> *names) {
    for (NSString *name in names) {
        Class cls = NSClassFromString(name);
        if (!cls) cls = objc_getClass(name.UTF8String);
        if (cls) return cls;
    }
    return Nil;
}

static void MBPReplaceInstanceMethod(Class cls, SEL sel, IMP replacement) {
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
}

static void MBPHookNeedInvitationCode(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);
    SEL sel = NSSelectorFromString(@"needInvitationCode");

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        Method instanceMethod = class_getInstanceMethod(cls, sel);
        if (instanceMethod) method_setImplementation(instanceMethod, (IMP)MBPFalseBool);

        Method classMethod = class_getClassMethod(cls, sel);
        if (classMethod) method_setImplementation(classMethod, (IMP)MBPFalseBool);
    }
    free(classes);
}

static void MBPHookLoginClasses(void) {
    NSArray<NSArray<NSString *> *> *groups = @[
        @[@"GoogleAdsSDK.MBLoginBaseViewController", @"_TtC12GoogleAdsSDK25MBLoginBaseViewController", @"MBLoginBaseViewController"],
        @[@"GoogleAdsSDK.MBCodeLoginViewController", @"_TtC12GoogleAdsSDK25MBCodeLoginViewController", @"MBCodeLoginViewController"],
        @[@"GoogleAdsSDK.MBInvitationCodeLoginController", @"_TtC12GoogleAdsSDK31MBInvitationCodeLoginController", @"MBInvitationCodeLoginController"],
        @[@"GoogleAdsSDK.TVCodeLoginController", @"_TtC12GoogleAdsSDK21TVCodeLoginController", @"TVCodeLoginController"]
    ];

    for (NSArray<NSString *> *names in groups) {
        Class cls = MBPFindClass(names);
        if (!cls) continue;
        MBPReplaceInstanceMethod(cls, @selector(viewDidLoad), (IMP)MBPLoginViewDidLoad);
        MBPReplaceInstanceMethod(cls, @selector(viewDidAppear:), (IMP)MBPLoginViewDidAppear);
    }
}

static void MBPHookUIKitRouting(void) {
    Method present = class_getInstanceMethod(UIViewController.class, @selector(presentViewController:animated:completion:));
    if (present && method_getImplementation(present) != (IMP)MBPPresentReplacement) {
        gPresentIMP = method_getImplementation(present);
        method_setImplementation(present, (IMP)MBPPresentReplacement);
    }

    Method push = class_getInstanceMethod(UINavigationController.class, @selector(pushViewController:animated:));
    if (push && method_getImplementation(push) != (IMP)MBPPushReplacement) {
        gPushIMP = method_getImplementation(push);
        method_setImplementation(push, (IMP)MBPPushReplacement);
    }
}

static void MBPInstallHooks(void) {
    MBPStableInstallID();
    MBPHookUIKitRouting();
    MBPHookNeedInvitationCode();
    MBPHookLoginClasses();
    MBPSweepVisibleLogin();
}

__attribute__((constructor))
static void MBPGuestBootstrapInit(void) {
    @autoreleasepool {
        MBPStableInstallID();
        MBPInstallHooks();

        dispatch_async(dispatch_get_main_queue(), ^{
            MBPInstallHooks();
            for (NSInteger i = 1; i <= 20; i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * i * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    MBPInstallHooks();
                });
            }
        });
    }
}
