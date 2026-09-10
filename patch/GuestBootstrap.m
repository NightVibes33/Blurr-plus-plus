#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kService = @"com.xd.mbp31.persistent-guest";
static NSString *const kInstallAccount = @"install-id";
static NSString *const kGuestUserAccount = @"owned-guest-user-id";
static NSString *const kGuestUsernameAccount = @"owned-guest-username";
static NSString *const kAccessAccount = @"owned-guest-access-token";
static NSString *const kRefreshAccount = @"owned-guest-refresh-token";
static NSString *const kUserChangedNotification = @"MBUserStatusChangedNotification";
static NSString *const kBootstrapURL = @"https://movieboxpro-guest-auth.lovable.app/api/public/guest/bootstrap";
static NSString *const kRefreshURL = @"https://movieboxpro-guest-auth.lovable.app/api/public/guest/refresh";
static NSInteger const kOverlayTag = 0x4D425047;

static const void *kOrigAppFirstLoadKey = &kOrigAppFirstLoadKey;
static const void *kGuestMarkerKey = &kGuestMarkerKey;

typedef NS_ENUM(NSInteger, GuestState) {
    GuestStateIdle = 0,
    GuestStateBootstrapping = 1,
    GuestStateReady = 2,
    GuestStateTerminalFailure = 3,
};

static GuestState gState = GuestStateIdle;
static NSInteger gWatchdogTicks = 0;
static BOOL gDidRouteOnce = NO;
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

static BOOL HasCachedGuest(void) {
    return KeychainRead(kGuestUserAccount).length > 0;
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
    if (!name.length) return NO;
    return [name containsString:@"MBLoginBaseViewController"] ||
           [name containsString:@"MBCodeLoginViewController"] ||
           [name containsString:@"MBInvitationCodeLoginController"] ||
           [name containsString:@"MBInputInvitationController"] ||
           [name containsString:@"TVCodeLoginController"] ||
           ([name containsString:@"GoogleAdsSDK"] &&
            ([name containsString:@"Login"] || [name containsString:@"Invitation"]));
}

static unsigned long long StableNumericID(NSString *value) {
    const unsigned char *bytes = (const unsigned char *)value.UTF8String;
    unsigned long long hash = 1469598103934665603ULL;
    if (bytes) {
        for (const unsigned char *p = bytes; *p; ++p) {
            hash ^= (unsigned long long)(*p);
            hash *= 1099511628211ULL;
        }
    }
    hash &= 0x3fffffffffffffffULL;
    return hash ? hash : 1ULL;
}

static void SafeSet(id object, NSString *key, id value) {
    if (!object || !key.length || !value) return;
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static id CreateGuestUser(NSString *guestID, NSString *username) {
    Class userClass = FindClass(@[
        @"GoogleAdsSDK.MBUser",
        @"_TtC12GoogleAdsSDK6MBUser",
        @"MBUser"
    ]);
    if (!userClass) return nil;

    id user = [[userClass alloc] init];
    if (!user) return nil;

    NSString *resolvedUsername = username.length ? username : @"guest";
    SafeSet(user, @"uid", @(StableNumericID(guestID)));
    SafeSet(user, @"username", resolvedUsername);
    SafeSet(user, @"nickname", resolvedUsername);
    SafeSet(user, @"email", @"");
    SafeSet(user, @"isVip", @NO);
    objc_setAssociatedObject(user, kGuestMarkerKey, guestID, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return user;
}

static Ivar UserIvarForManager(id manager) {
    if (!manager) return NULL;
    Ivar ivar = class_getInstanceVariable([manager class], "user");
    if (!ivar) ivar = class_getInstanceVariable([manager class], "_user");
    return ivar;
}

static BOOL ManagerAlreadyHasUser(id manager) {
    Ivar ivar = UserIvarForManager(manager);
    return ivar && object_getIvar(manager, ivar) != nil;
}

static BOOL InjectGuestIntoManager(id manager) {
    NSString *guestID = KeychainRead(kGuestUserAccount);
    if (!manager || !guestID.length) return NO;

    Ivar userIvar = UserIvarForManager(manager);
    if (!userIvar) return NO;

    id existing = object_getIvar(manager, userIvar);
    if (existing && !objc_getAssociatedObject(existing, kGuestMarkerKey)) {
        return YES; // Never overwrite a legitimate MovieBox user.
    }

    NSString *username = KeychainRead(kGuestUsernameAccount);
    id guest = existing ?: CreateGuestUser(guestID, username);
    if (!guest) return NO;
    if (!existing) object_setIvar(manager, userIvar, guest);

    [[NSUserDefaults standardUserDefaults] setObject:guestID forKey:@"MBPGuestUserID"];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"MBPGuestBootstrapComplete"];
    return YES;
}

static id ResolveUserManager(void) {
    if (gUserManager) return gUserManager;
    Class cls = FindClass(@[
        @"GoogleAdsSDK.MBUserManager",
        @"_TtC12GoogleAdsSDK13MBUserManager",
        @"MBUserManager"
    ]);
    if (!cls) return nil;

    NSArray<NSString *> *selectors = @[@"shared", @"sharedManager", @"sharedInstance", @"defaultManager"];
    for (NSString *name in selectors) {
        SEL sel = NSSelectorFromString(name);
        if ([(id)cls respondsToSelector:sel]) {
            id value = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel);
            if (value) {
                gUserManager = value;
                return value;
            }
        }
    }
    return nil;
}

static UIViewController *VisibleController(UIViewController *vc) {
    if (!vc) return nil;
    if (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
        return VisibleController(vc.presentedViewController);
    }
    if ([vc isKindOfClass:UINavigationController.class]) {
        return VisibleController(((UINavigationController *)vc).topViewController ?: vc);
    }
    if ([vc isKindOfClass:UITabBarController.class]) {
        return VisibleController(((UITabBarController *)vc).selectedViewController ?: vc);
    }
    for (UIViewController *child in [vc childViewControllers].reverseObjectEnumerator) {
        if (child.viewIfLoaded.window) {
            UIViewController *found = VisibleController(child);
            if (found) return found;
        }
    }
    return vc;
}

static UIWindow *KeyWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState == UISceneActivationStateUnattached) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
            if (!fallback && window.rootViewController) fallback = window;
        }
    }
    return fallback;
}

static void ShowGuestStatus(UIViewController *vc, NSString *message, BOOL failed) {
    if (!vc || !message.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!vc.view) return;
        UIView *old = [vc.view viewWithTag:kOverlayTag];
        [old removeFromSuperview];

        UIView *cover = [[UIView alloc] initWithFrame:vc.view.bounds];
        cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        cover.backgroundColor = UIColor.blackColor;
        cover.tag = kOverlayTag;

        UILabel *label = [[UILabel alloc] init];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        label.text = message;
        [cover addSubview:label];

        NSMutableArray *constraints = [NSMutableArray arrayWithObjects:
            [label.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
            [label.centerYAnchor constraintEqualToAnchor:cover.centerYAnchor],
            [label.leadingAnchor constraintGreaterThanOrEqualToAnchor:cover.leadingAnchor constant:28],
            [label.trailingAnchor constraintLessThanOrEqualToAnchor:cover.trailingAnchor constant:-28], nil];

        if (!failed) {
            UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
            spinner.translatesAutoresizingMaskIntoConstraints = NO;
            [spinner startAnimating];
            [cover addSubview:spinner];
            [constraints addObject:[spinner.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor]];
            [constraints addObject:[spinner.bottomAnchor constraintEqualToAnchor:label.topAnchor constant:-20]];
        }

        [NSLayoutConstraint activateConstraints:constraints];
        [vc.view addSubview:cover];
        [vc.view bringSubviewToFront:cover];
    });
}

static NSString *BackendErrorMessage(NSData *data, NSHTTPURLResponse *http, NSError *error) {
    if (error.localizedDescription.length) return error.localizedDescription;
    if (data.length) {
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:NSDictionary.class]) {
            NSDictionary *err = [parsed[@"error"] isKindOfClass:NSDictionary.class] ? parsed[@"error"] : nil;
            NSString *message = [err[@"message"] isKindOfClass:NSString.class] ? err[@"message"] : nil;
            if (message.length) return message;
        }
    }
    return [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode];
}

static UIViewController *CreateMainController(void) {
    Class cls = FindClass(@[
        @"GoogleAdsSDK.MBTabBarController",
        @"_TtC12GoogleAdsSDK18MBTabBarController",
        @"MBTabBarController"
    ]);
    if (!cls) return nil;
    id object = [[cls alloc] init];
    return [object isKindOfClass:UIViewController.class] ? object : nil;
}

static void RoutePastLogin(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gDidRouteOnce) return;
        UIViewController *login = gLoginController;
        if (!login || !HasCachedGuest()) return;

        id manager = ResolveUserManager();
        if (manager && !InjectGuestIntoManager(manager)) {
            gState = GuestStateTerminalFailure;
            ShowGuestStatus(login, @"Guest account exists, but MovieBox could not attach it to MBUserManager.", YES);
            return;
        }

        [[NSNotificationCenter defaultCenter] postNotificationName:kUserChangedNotification
                                                            object:nil
                                                          userInfo:@{ @"guest": @YES,
                                                                      @"user_id": KeychainRead(kGuestUserAccount) ?: @"" }];

        gDidRouteOnce = YES;
        if (login.presentingViewController) {
            [login.presentingViewController dismissViewControllerAnimated:NO completion:nil];
            return;
        }

        UINavigationController *nav = login.navigationController;
        if (nav && nav.topViewController == login && nav.viewControllers.count > 1) {
            [nav popViewControllerAnimated:NO];
            return;
        }

        UIWindow *window = login.viewIfLoaded.window ?: KeyWindow();
        UIViewController *main = CreateMainController();
        if (!window || !main) {
            gState = GuestStateTerminalFailure;
            ShowGuestStatus(login, @"Guest account is ready, but the main MovieBox controller could not be created.", YES);
            return;
        }

        [UIView performWithoutAnimation:^{
            window.rootViewController = main;
            [window makeKeyAndVisible];
            [window layoutIfNeeded];
        }];
    });
}

static void PersistGuestResponse(NSDictionary *json) {
    NSDictionary *user = [json[@"user"] isKindOfClass:NSDictionary.class] ? json[@"user"] : nil;
    NSDictionary *session = [json[@"session"] isKindOfClass:NSDictionary.class] ? json[@"session"] : nil;
    NSString *userID = [user[@"id"] isKindOfClass:NSString.class] ? user[@"id"] : nil;
    NSString *username = [user[@"username"] isKindOfClass:NSString.class] ? user[@"username"] : nil;
    NSString *access = [session[@"access_token"] isKindOfClass:NSString.class] ? session[@"access_token"] : nil;
    NSString *refresh = [session[@"refresh_token"] isKindOfClass:NSString.class] ? session[@"refresh_token"] : nil;

    if (!userID.length || !access.length || !refresh.length) {
        gState = GuestStateTerminalFailure;
        UIViewController *login = gLoginController;
        if (login) ShowGuestStatus(login, @"Guest backend returned an incomplete session.", YES);
        return;
    }

    KeychainWrite(kGuestUserAccount, userID);
    if (username.length) KeychainWrite(kGuestUsernameAccount, username);
    KeychainWrite(kAccessAccount, access);
    KeychainWrite(kRefreshAccount, refresh);
    gState = GuestStateReady;

    id manager = ResolveUserManager();
    if (manager) InjectGuestIntoManager(manager);
    RoutePastLogin();
}

static void PostJSON(NSString *urlString, NSDictionary *payload, void (^completion)(NSDictionary *json, NSString *errorMessage)) {
    NSError *bodyError = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&bodyError];
    if (!body || bodyError) {
        completion(nil, bodyError.localizedDescription ?: @"Could not encode request");
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 20.0;
    request.HTTPBody = body;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (error || ![http isKindOfClass:NSHTTPURLResponse.class] || http.statusCode < 200 || http.statusCode >= 300) {
            completion(nil, BackendErrorMessage(data, http, error));
            return;
        }
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![parsed isKindOfClass:NSDictionary.class]) {
            completion(nil, @"Backend returned invalid JSON");
            return;
        }
        completion((NSDictionary *)parsed, nil);
    }] resume];
}

static void RefreshOwnedGuest(void) {
    NSString *refresh = KeychainRead(kRefreshAccount);
    if (!refresh.length) return;

    PostJSON(kRefreshURL, @{ @"refresh_token": refresh }, ^(NSDictionary *json, NSString *errorMessage) {
        if (json) {
            PersistGuestResponse(json);
        } else {
            NSLog(@"[MBPGuestBootstrap] refresh failed: %@", errorMessage);
        }
    });
}

static void EnsureOwnedGuest(void) {
    if (gState == GuestStateBootstrapping || gState == GuestStateTerminalFailure) return;

    if (HasCachedGuest()) {
        gState = GuestStateReady;
        id manager = ResolveUserManager();
        if (manager) InjectGuestIntoManager(manager);
        RoutePastLogin();
        RefreshOwnedGuest();
        return;
    }

    gState = GuestStateBootstrapping;
    UIViewController *login = gLoginController;
    if (login) ShowGuestStatus(login, @"Creating your persistent guest account…", NO);

    NSString *installID = StableInstallID();
    PostJSON(kBootstrapURL, @{ @"install_id": installID }, ^(NSDictionary *json, NSString *errorMessage) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!json) {
                gState = GuestStateTerminalFailure;
                UIViewController *visibleLogin = gLoginController;
                if (visibleLogin) {
                    ShowGuestStatus(visibleLogin,
                        [NSString stringWithFormat:@"Guest backend setup failed:\n%@", errorMessage ?: @"unknown error"], YES);
                }
                return;
            }
            PersistGuestResponse(json);
        });
    });
}

static void UserManagerAppFirstLoad(id self, SEL _cmd) {
    NSValue *stored = objc_getAssociatedObject((id)[self class], kOrigAppFirstLoadKey);
    IMP original = stored ? [stored pointerValue] : NULL;
    if (original && original != (IMP)UserManagerAppFirstLoad) {
        ((void (*)(id, SEL))original)(self, _cmd);
    }
    gUserManager = self;
    if (!ManagerAlreadyHasUser(self) && HasCachedGuest()) InjectGuestIntoManager(self);
}

static BOOL HookUserManager(void) {
    Class cls = FindClass(@[
        @"GoogleAdsSDK.MBUserManager",
        @"_TtC12GoogleAdsSDK13MBUserManager",
        @"MBUserManager"
    ]);
    if (!cls) return NO;
    if (objc_getAssociatedObject((id)cls, kOrigAppFirstLoadKey)) return YES;

    SEL selector = NSSelectorFromString(@"appFirstLoad");
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    IMP original = method_getImplementation(method);
    if (!original) return NO;

    method_setImplementation(method, (IMP)UserManagerAppFirstLoad);
    objc_setAssociatedObject((id)cls, kOrigAppFirstLoadKey, [NSValue valueWithPointer:original], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

static void WatchdogTick(void) {
    if (gWatchdogTicks++ >= 120) return;
    HookUserManager();
    ResolveUserManager();

    UIWindow *window = KeyWindow();
    UIViewController *visible = VisibleController(window.rootViewController);
    if (visible && IsLoginController(visible)) {
        gLoginController = visible;

        if (gState == GuestStateTerminalFailure) {
            return; // Terminal means terminal: no retry/spam loop.
        }

        if (HasCachedGuest()) {
            if (gState != GuestStateReady) ShowGuestStatus(visible, @"Restoring your persistent guest account…", NO);
        } else if (gState == GuestStateIdle) {
            ShowGuestStatus(visible, @"Creating your persistent guest account…", NO);
        }
        EnsureOwnedGuest();
    }

    if (gState != GuestStateTerminalFailure && (!gDidRouteOnce || (visible && IsLoginController(visible)))) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.50 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WatchdogTick();
        });
    }
}

__attribute__((constructor)) static void GuestBootstrapInit(void) {
    @autoreleasepool {
        StableInstallID();
        HookUserManager();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WatchdogTick();
        });
    }
}
