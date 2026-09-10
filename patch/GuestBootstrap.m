#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kGuestService = @"com.xd.mbp31.persistent-guest";
static NSString *const kGuestAccount = @"install-id";
static NSString *const kGuestDefaultsKey = @"MBPStableGuestInstallID";
static NSString *const kUserChangedNotification = @"MBUserStatusChangedNotification";

static const void *kOrigDidAppearKey = &kOrigDidAppearKey;
static BOOL gBootstrapStarted = NO;
static BOOL gInstalledMainRoot = NO;
static id gBootstrapController = nil;
static __weak UIViewController *gLoginController = nil;
static id gUserObserver = nil;

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
    SecItemAdd((__bridge CFDictionaryRef)item, NULL);

    [[NSUserDefaults standardUserDefaults] setObject:generated forKey:kGuestDefaultsKey];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"MBPPersistentGuestEnabled"];
    return generated;
}

static Class MBPFindClass(NSArray<NSString *> *names) {
    for (NSString *name in names) {
        Class cls = NSClassFromString(name);
        if (!cls) cls = objc_getClass(name.UTF8String);
        if (cls) return cls;
    }
    return Nil;
}

static BOOL MBPIsMovieBoxLoginController(id object) {
    if (!object) return NO;
    NSString *name = NSStringFromClass([object class]);
    return [name containsString:@"MBLoginBaseViewController"] ||
           [name containsString:@"MBCodeLoginViewController"] ||
           [name containsString:@"MBInvitationCodeLoginController"] ||
           [name containsString:@"TVCodeLoginController"];
}

static UIWindow *MBPWindowForController(UIViewController *vc) {
    UIWindow *window = vc.viewIfLoaded.window;
    if (window) return window;
    window = vc.navigationController.viewIfLoaded.window;
    if (window) return window;
    window = vc.presentingViewController.viewIfLoaded.window;
    if (window) return window;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) return candidate;
            if (!window && candidate.rootViewController) window = candidate;
        }
    }
    return window;
}

static UIViewController *MBPCreateMainController(void) {
    Class cls = MBPFindClass(@[
        @"GoogleAdsSDK.MBTabBarController",
        @"_TtC12GoogleAdsSDK18MBTabBarController",
        @"MBTabBarController"
    ]);
    if (!cls) return nil;
    id obj = ((id (*)(id, SEL))objc_msgSend)((id)cls, @selector(alloc));
    obj = ((id (*)(id, SEL))objc_msgSend)(obj, @selector(init));
    return [obj isKindOfClass:UIViewController.class] ? obj : nil;
}

static void MBPRouteToMain(void) {
    if (gInstalledMainRoot) return;
    UIViewController *loginVC = gLoginController;
    UIWindow *window = MBPWindowForController(loginVC);
    UIViewController *main = MBPCreateMainController();
    if (!window || !main) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!gInstalledMainRoot) MBPRouteToMain();
        });
        return;
    }

    gInstalledMainRoot = YES;
    [UIView performWithoutAnimation:^{
        window.rootViewController = main;
        [window makeKeyAndVisible];
        [window layoutIfNeeded];
    }];
    NSLog(@"[MBPGuestBootstrap] session accepted; installed MBTabBarController");
}

static UIView *MBPBootstrapCover(UIViewController *vc) {
    UIView *cover = [vc.view viewWithTag:0x4D425047];
    if (cover) return cover;

    cover = [[UIView alloc] initWithFrame:vc.view.bounds];
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cover.backgroundColor = UIColor.blackColor;
    cover.tag = 0x4D425047;

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [spinner startAnimating];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"Setting up your guest account…";
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];

    [cover addSubview:spinner];
    [cover addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
        [spinner.centerYAnchor constraintEqualToAnchor:cover.centerYAnchor constant:-18],
        [label.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
        [label.topAnchor constraintEqualToAnchor:spinner.bottomAnchor constant:18]
    ]];
    [vc.view addSubview:cover];
    return cover;
}

static void MBPShowBootstrapFailure(NSString *message) {
    UIViewController *vc = gLoginController;
    if (!vc) return;
    UIView *cover = MBPBootstrapCover(vc);
    for (UIView *subview in cover.subviews) [subview removeFromSuperview];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(cover.bounds, 28, 80)];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    label.text = message;
    [cover addSubview:label];
}

static NSString *MBPSanitizedInstallID(void) {
    NSString *raw = [[MBPStableInstallID() stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
    if (raw.length > 24) raw = [raw substringToIndex:24];
    return raw;
}

static void MBPAttemptNativeThirdPartyLogin(UIViewController *loginVC) {
    if (gBootstrapStarted) return;
    gBootstrapStarted = YES;
    gLoginController = loginVC;
    MBPBootstrapCover(loginVC);

    if (!gUserObserver) {
        gUserObserver = [[NSNotificationCenter defaultCenter] addObserverForName:kUserChangedNotification
                                                                         object:nil
                                                                          queue:NSOperationQueue.mainQueue
                                                                     usingBlock:^(__unused NSNotification *note) {
            NSLog(@"[MBPGuestBootstrap] MBUserStatusChangedNotification received");
            MBPRouteToMain();
        }];
    }

    Class accountClass = MBPFindClass(@[
        @"GoogleAdsSDK.MBAccountViewController",
        @"_TtC12GoogleAdsSDK23MBAccountViewController",
        @"MBAccountViewController"
    ]);
    SEL loginSel = NSSelectorFromString(@"thirdPartLoginWithUserInfo:needUploadAvatar:");
    if (!accountClass || !class_getInstanceMethod(accountClass, loginSel)) {
        MBPShowBootstrapFailure(@"Guest account setup is unavailable in this build (Login_thirdpart selector not found).");
        return;
    }

    id controller = ((id (*)(id, SEL))objc_msgSend)((id)accountClass, @selector(alloc));
    controller = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(init));
    if (!controller) {
        MBPShowBootstrapFailure(@"Guest account setup could not initialize the account controller.");
        return;
    }
    gBootstrapController = controller;

    NSString *openid = MBPStableInstallID();
    NSString *idPart = MBPSanitizedInstallID();
    NSString *username = [@"guest" stringByAppendingString:idPart];
    NSString *email = [NSString stringWithFormat:@"%@@guest.invalid", username];

    /* Supply every spelling used by the client-side auth tuples.  The native
       controller remains responsible for constructing and sending Login_thirdpart
       and for persisting any returned MBUser/session_credential. */
    NSDictionary *userInfo = @{
        @"type": @"guest",
        @"openid": openid,
        @"openId": openid,
        @"sub": openid,
        @"uid": openid,
        @"accesstoken": openid,
        @"accessToken": openid,
        @"id_token": openid,
        @"name": username,
        @"nick": username,
        @"nickname": username,
        @"email": email
    };

    NSLog(@"[MBPGuestBootstrap] starting native Login_thirdpart guest bootstrap for %@", username);
    ((void (*)(id, SEL, NSDictionary *, BOOL))objc_msgSend)(controller,
                                                            loginSel,
                                                            userInfo,
                                                            NO);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!gInstalledMainRoot) {
            MBPShowBootstrapFailure(@"Guest Login_thirdpart did not produce a valid session. This server build does not appear to accept the guest identity type yet.");
        }
    });
}

static NSValue *MBPOriginalValue(Class cls) {
    for (Class current = cls; current != Nil; current = class_getSuperclass(current)) {
        NSValue *value = objc_getAssociatedObject((id)current, kOrigDidAppearKey);
        if (value) return value;
    }
    return nil;
}

static void MBPLoginDidAppear(id self, SEL _cmd, BOOL animated) {
    NSValue *stored = MBPOriginalValue([self class]);
    IMP original = stored ? [stored pointerValue] : NULL;
    if (original && original != (IMP)MBPLoginDidAppear) {
        ((void (*)(id, SEL, BOOL))original)(self, _cmd, animated);
    }

    if ([self isKindOfClass:UIViewController.class]) {
        UIViewController *vc = (UIViewController *)self;
        dispatch_async(dispatch_get_main_queue(), ^{
            MBPAttemptNativeThirdPartyLogin(vc);
        });
    }
}

static BOOL MBPHookClass(Class cls) {
    if (!cls) return NO;
    if (objc_getAssociatedObject((id)cls, kOrigDidAppearKey)) return YES;
    Method inherited = class_getInstanceMethod(cls, @selector(viewDidAppear:));
    if (!inherited) return NO;
    IMP original = method_getImplementation(inherited);
    const char *types = method_getTypeEncoding(inherited);
    if (!original || !types) return NO;

    if (!class_addMethod(cls, @selector(viewDidAppear:), (IMP)MBPLoginDidAppear, types)) {
        Method own = class_getInstanceMethod(cls, @selector(viewDidAppear:));
        if (!own) return NO;
        original = method_getImplementation(own);
        if (original != (IMP)MBPLoginDidAppear) method_setImplementation(own, (IMP)MBPLoginDidAppear);
    }
    objc_setAssociatedObject((id)cls, kOrigDidAppearKey, [NSValue valueWithPointer:original], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

static BOOL MBPHookLoginClasses(void) {
    NSArray<NSArray<NSString *> *> *groups = @[
        @[@"GoogleAdsSDK.MBLoginBaseViewController", @"_TtC12GoogleAdsSDK25MBLoginBaseViewController", @"MBLoginBaseViewController"],
        @[@"GoogleAdsSDK.MBCodeLoginViewController", @"_TtC12GoogleAdsSDK25MBCodeLoginViewController", @"MBCodeLoginViewController"],
        @[@"GoogleAdsSDK.MBInvitationCodeLoginController", @"_TtC12GoogleAdsSDK31MBInvitationCodeLoginController", @"MBInvitationCodeLoginController"],
        @[@"GoogleAdsSDK.TVCodeLoginController", @"_TtC12GoogleAdsSDK21TVCodeLoginController", @"TVCodeLoginController"]
    ];
    BOOL found = NO;
    for (NSArray<NSString *> *names in groups) {
        Class cls = MBPFindClass(names);
        if (cls) found |= MBPHookClass(cls);
    }
    return found;
}

static void MBPInstallHooks(void) {
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
        dispatch_async(dispatch_get_main_queue(), ^{ MBPInstallHooks(); });
    }
}
