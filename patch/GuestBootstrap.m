#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>

static NSString *const kService = @"com.xd.mbp31.persistent-guest";
static NSString *const kInstallAccount = @"install-id";
static NSString *const kGuestUserAccount = @"guest-user-id";
static NSString *const kAccessAccount = @"guest-access-token";
static NSString *const kRefreshAccount = @"guest-refresh-token";
static NSString *const kUserChangedNotification = @"MBUserStatusChangedNotification";

static const void *kOrigDidAppearKey = &kOrigDidAppearKey;
static const void *kOrigAppFirstLoadKey = &kOrigAppFirstLoadKey;
static BOOL gBootstrapStarted = NO;
static __weak id gUserManager = nil;
static __weak UIViewController *gLoginController = nil;

static NSDictionary *KeychainBase(NSString *account) {
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kService,
        (__bridge id)kSecAttrAccount: account
    };
}

static NSString *KeychainRead(NSString *account) {
    NSMutableDictionary *q = [KeychainBase(account) mutableCopy];
    q[(__bridge id)kSecReturnData] = @YES;
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
    if (status != errSecSuccess || !result) return nil;
    NSData *data = CFBridgingRelease(result);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static void KeychainWrite(NSString *account, NSString *value) {
    if (!account.length || !value.length) return;
    NSDictionary *base = KeychainBase(account);
    SecItemDelete((__bridge CFDictionaryRef)base);
    NSMutableDictionary *item = [base mutableCopy];
    item[(__bridge id)kSecValueData] = [value dataUsingEncoding:NSUTF8StringEncoding];
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    SecItemAdd((__bridge CFDictionaryRef)item, NULL);
}

static NSString *StableInstallID(void) {
    NSString *value = KeychainRead(kInstallAccount);
    if (value.length) return value;
    value = NSUUID.UUID.UUIDString.lowercaseString;
    KeychainWrite(kInstallAccount, value);
    return value;
}

static NSURL *BootstrapURL(void) {
    id raw = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"MBPGuestBootstrapURL"];
    if (![raw isKindOfClass:NSString.class] || ![(NSString *)raw length]) return nil;
    NSURL *url = [NSURL URLWithString:(NSString *)raw];
    if (!url || ![url.scheme.lowercaseString isEqualToString:@"https"]) return nil;
    return url;
}

static Class FindClass(NSArray<NSString *> *names) {
    for (NSString *name in names) {
        Class cls = NSClassFromString(name);
        if (!cls) cls = objc_getClass(name.UTF8String);
        if (cls) return cls;
    }
    return Nil;
}

static BOOL IsLoginController(id object) {
    if (!object) return NO;
    NSString *name = NSStringFromClass([object class]);
    return [name containsString:@"MBLoginBaseViewController"] ||
           [name containsString:@"MBCodeLoginViewController"] ||
           [name containsString:@"MBInvitationCodeLoginController"] ||
           [name containsString:@"TVCodeLoginController"];
}

static BOOL HasCachedGuest(void) {
    return KeychainRead(kGuestUserAccount).length > 0;
}

static id CreateGuestUser(void) {
    Class userClass = FindClass(@[
        @"GoogleAdsSDK.MBUser",
        @"_TtC12GoogleAdsSDK6MBUser",
        @"MBUser"
    ]);
    if (!userClass) {
        NSLog(@"[MBPGuestBootstrap] MBUser class not found");
        return nil;
    }

    id user = [[userClass alloc] init];
    if (!user) NSLog(@"[MBPGuestBootstrap] MBUser init failed");
    return user;
}

static BOOL ManagerAlreadyHasUser(id manager) {
    if (!manager) return NO;
    Ivar userIvar = class_getInstanceVariable([manager class], "user");
    if (!userIvar) return NO;
    return object_getIvar(manager, userIvar) != nil;
}

static BOOL InjectGuestIntoManager(id manager) {
    if (!manager || !HasCachedGuest()) return NO;

    Ivar userIvar = class_getInstanceVariable([manager class], "user");
    if (!userIvar) {
        NSLog(@"[MBPGuestBootstrap] MBUserManager.user ivar not found");
        return NO;
    }

    if (object_getIvar(manager, userIvar)) {
        return YES; // Preserve a legitimate user loaded by the app.
    }

    id guest = CreateGuestUser();
    if (!guest) return NO;

    NSString *guestID = KeychainRead(kGuestUserAccount);
    objc_setAssociatedObject(guest, @selector(InjectGuestIntoManager:), guestID, OBJC_ASSOCIATION_COPY_NONATOMIC);
    object_setIvar(manager, userIvar, guest);

    if (object_getIvar(manager, userIvar) != guest) {
        NSLog(@"[MBPGuestBootstrap] failed to populate MBUserManager.user");
        return NO;
    }

    [[NSUserDefaults standardUserDefaults] setObject:guestID forKey:@"MBPGuestUserID"];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"MBPGuestBootstrapComplete"];
    [[NSNotificationCenter defaultCenter] postNotificationName:kUserChangedNotification
                                                        object:nil
                                                      userInfo:@{ @"guest": @YES, @"user_id": guestID ?: @"" }];
    NSLog(@"[MBPGuestBootstrap] injected cached guest into MBUserManager: %@", guestID);
    return YES;
}

static UIWindow *WindowForController(UIViewController *vc) {
    UIWindow *window = vc.viewIfLoaded.window;
    if (window) return window;
    window = vc.navigationController.viewIfLoaded.window;
    if (window) return window;
    window = vc.presentingViewController.viewIfLoaded.window;
    return window;
}

static UIViewController *CreateMainController(void) {
    Class cls = FindClass(@[
        @"GoogleAdsSDK.MBTabBarController",
        @"_TtC12GoogleAdsSDK18MBTabBarController",
        @"MBTabBarController"
    ]);
    if (!cls) return nil;
    id obj = [[cls alloc] init];
    return [obj isKindOfClass:UIViewController.class] ? obj : nil;
}

static void RoutePastLogin(UIViewController *loginVC) {
    if (!loginVC || !HasCachedGuest()) return;
    if (gUserManager) InjectGuestIntoManager(gUserManager);

    if (loginVC.presentingViewController) {
        [loginVC.presentingViewController dismissViewControllerAnimated:NO completion:nil];
        return;
    }

    UINavigationController *nav = loginVC.navigationController;
    if (nav && nav.topViewController == loginVC && nav.viewControllers.count > 1) {
        [nav popViewControllerAnimated:NO];
        return;
    }

    UIWindow *window = WindowForController(loginVC);
    if (!window) return;
    UIViewController *main = CreateMainController();
    if (!main) return;

    [UIView performWithoutAnimation:^{
        window.rootViewController = main;
        [window makeKeyAndVisible];
        [window layoutIfNeeded];
    }];
}

static void PersistBootstrapResponse(NSDictionary *json) {
    NSDictionary *user = [json[@"user"] isKindOfClass:NSDictionary.class] ? json[@"user"] : nil;
    NSDictionary *session = [json[@"session"] isKindOfClass:NSDictionary.class] ? json[@"session"] : nil;
    NSString *userID = [user[@"id"] isKindOfClass:NSString.class] ? user[@"id"] : nil;
    NSString *access = [session[@"access_token"] isKindOfClass:NSString.class] ? session[@"access_token"] : nil;
    NSString *refresh = [session[@"refresh_token"] isKindOfClass:NSString.class] ? session[@"refresh_token"] : nil;
    if (!userID.length || !access.length || !refresh.length) {
        NSLog(@"[MBPGuestBootstrap] bootstrap response missing required fields");
        return;
    }

    KeychainWrite(kGuestUserAccount, userID);
    KeychainWrite(kAccessAccount, access);
    KeychainWrite(kRefreshAccount, refresh);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSUserDefaults standardUserDefaults] setObject:userID forKey:@"MBPGuestUserID"];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"MBPGuestBootstrapComplete"];
        if (gUserManager) InjectGuestIntoManager(gUserManager);
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MBPOwnedGuestSessionReadyNotification"
                                                            object:nil
                                                          userInfo:@{ @"user_id": userID }];
        UIViewController *loginVC = gLoginController;
        if (loginVC) RoutePastLogin(loginVC);
    });
}

static void BootstrapOwnedGuest(void) {
    if (gBootstrapStarted) return;
    gBootstrapStarted = YES;

    // Cached identity is immediately usable on restart/offline. Still renew in background.
    if (HasCachedGuest() && gUserManager) InjectGuestIntoManager(gUserManager);

    NSURL *url = BootstrapURL();
    if (!url) {
        NSLog(@"[MBPGuestBootstrap] MBPGuestBootstrapURL is not configured");
        return;
    }

    NSError *jsonError = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:@{ @"install_id": StableInstallID() }
                                                   options:0
                                                     error:&jsonError];
    if (!body || jsonError) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    request.timeoutInterval = 15.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"[MBPGuestBootstrap] guest bootstrap network error: %@", error);
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (![http isKindOfClass:NSHTTPURLResponse.class] || http.statusCode < 200 || http.statusCode >= 300 || !data.length) {
            NSLog(@"[MBPGuestBootstrap] guest bootstrap HTTP failure: %ld", (long)http.statusCode);
            return;
        }
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![parsed isKindOfClass:NSDictionary.class]) {
            NSLog(@"[MBPGuestBootstrap] guest bootstrap returned invalid JSON");
            return;
        }
        PersistBootstrapResponse((NSDictionary *)parsed);
    }] resume];
}

static NSValue *OriginalDidAppearValue(Class cls) {
    for (Class current = cls; current != Nil; current = class_getSuperclass(current)) {
        NSValue *value = objc_getAssociatedObject((id)current, kOrigDidAppearKey);
        if (value) return value;
    }
    return nil;
}

static void LoginDidAppear(id self, SEL _cmd, BOOL animated) {
    NSValue *stored = OriginalDidAppearValue([self class]);
    IMP original = stored ? [stored pointerValue] : NULL;
    if (original && original != (IMP)LoginDidAppear) {
        ((void (*)(id, SEL, BOOL))original)(self, _cmd, animated);
    }

    if (![self isKindOfClass:UIViewController.class] || !IsLoginController(self)) return;
    gLoginController = (UIViewController *)self;

    if (HasCachedGuest()) {
        if (gUserManager) InjectGuestIntoManager(gUserManager);
        dispatch_async(dispatch_get_main_queue(), ^{ RoutePastLogin((UIViewController *)self); });
    }
    BootstrapOwnedGuest();
}

static void UserManagerAppFirstLoad(id self, SEL _cmd) {
    NSValue *stored = objc_getAssociatedObject((id)[self class], kOrigAppFirstLoadKey);
    IMP original = stored ? [stored pointerValue] : NULL;
    if (original && original != (IMP)UserManagerAppFirstLoad) {
        ((void (*)(id, SEL))original)(self, _cmd);
    }

    gUserManager = self;
    if (!ManagerAlreadyHasUser(self) && HasCachedGuest()) {
        InjectGuestIntoManager(self);
    }
    BootstrapOwnedGuest();
}

static BOOL HookLoginClass(Class cls) {
    if (!cls) return NO;
    if (objc_getAssociatedObject((id)cls, kOrigDidAppearKey)) return YES;
    Method inherited = class_getInstanceMethod(cls, @selector(viewDidAppear:));
    if (!inherited) return NO;
    IMP original = method_getImplementation(inherited);
    const char *types = method_getTypeEncoding(inherited);
    if (!original || !types) return NO;

    if (!class_addMethod(cls, @selector(viewDidAppear:), (IMP)LoginDidAppear, types)) {
        Method own = class_getInstanceMethod(cls, @selector(viewDidAppear:));
        if (!own) return NO;
        original = method_getImplementation(own);
        if (original != (IMP)LoginDidAppear) method_setImplementation(own, (IMP)LoginDidAppear);
    }
    objc_setAssociatedObject((id)cls, kOrigDidAppearKey, [NSValue valueWithPointer:original], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

static BOOL HookUserManager(void) {
    Class cls = FindClass(@[
        @"GoogleAdsSDK.MBUserManager",
        @"_TtC12GoogleAdsSDK13MBUserManager",
        @"MBUserManager"
    ]);
    if (!cls) return NO;
    if (objc_getAssociatedObject((id)cls, kOrigAppFirstLoadKey)) return YES;

    SEL sel = NSSelectorFromString(@"appFirstLoad");
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;
    IMP original = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (!original || !types) return NO;

    method_setImplementation(method, (IMP)UserManagerAppFirstLoad);
    objc_setAssociatedObject((id)cls, kOrigAppFirstLoadKey, [NSValue valueWithPointer:original], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

static BOOL HookLoginClasses(void) {
    NSArray<NSArray<NSString *> *> *groups = @[
        @[@"GoogleAdsSDK.MBLoginBaseViewController", @"_TtC12GoogleAdsSDK25MBLoginBaseViewController", @"MBLoginBaseViewController"],
        @[@"GoogleAdsSDK.MBCodeLoginViewController", @"_TtC12GoogleAdsSDK25MBCodeLoginViewController", @"MBCodeLoginViewController"],
        @[@"GoogleAdsSDK.MBInvitationCodeLoginController", @"_TtC12GoogleAdsSDK31MBInvitationCodeLoginController", @"MBInvitationCodeLoginController"],
        @[@"GoogleAdsSDK.TVCodeLoginController", @"_TtC12GoogleAdsSDK21TVCodeLoginController", @"TVCodeLoginController"]
    ];
    BOOL found = NO;
    for (NSArray<NSString *> *names in groups) {
        Class cls = FindClass(names);
        if (cls) found |= HookLoginClass(cls);
    }
    return found;
}

static void InstallHooks(void) {
    BOOL managerReady = HookUserManager();
    BOOL loginReady = HookLoginClasses();
    if (managerReady && loginReady) return;

    __block NSInteger attempts = 0;
    __block void (^retry)(void) = nil;
    retry = ^{
        attempts++;
        BOOL m = HookUserManager();
        BOOL l = HookLoginClasses();
        if ((m && l) || attempts >= 120) {
            retry = nil;
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), retry);
    };
    dispatch_async(dispatch_get_main_queue(), retry);
}

__attribute__((constructor)) static void GuestBootstrapInit(void) {
    @autoreleasepool {
        // Runtime-only setup. No UIApplication traversal or network work in the constructor.
        InstallHooks();
    }
}
