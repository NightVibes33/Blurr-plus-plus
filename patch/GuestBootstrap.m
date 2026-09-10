#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kService = @"com.xd.mbp31.persistent-guest";
static NSString *const kInstallAccount = @"install-id";
static NSString *const kGuestUserAccount = @"firebase-guest-user-id";
static NSString *const kAccessAccount = @"firebase-id-token";
static NSString *const kRefreshAccount = @"firebase-refresh-token";
static NSString *const kUserChangedNotification = @"MBUserStatusChangedNotification";
static NSInteger const kOverlayTag = 0x4D425047;

static const void *kOrigAppFirstLoadKey = &kOrigAppFirstLoadKey;
static const void *kGuestMarkerKey = &kGuestMarkerKey;
static BOOL gBootstrapStarted = NO;
static BOOL gBootstrapFinished = NO;
static NSInteger gWatchdogTicks = 0;
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

static NSDictionary *FirebaseConfig(void) {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"GoogleService-Info" ofType:@"plist"];
    if (!path.length) return nil;
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:path];
    return [config isKindOfClass:NSDictionary.class] ? config : nil;
}

static NSString *FirebaseAPIKey(void) {
    id value = FirebaseConfig()[@"API_KEY"];
    return [value isKindOfClass:NSString.class] ? value : nil;
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

static BOOL HasCachedGuest(void) {
    return KeychainRead(kGuestUserAccount).length > 0;
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

static id CreateGuestUser(NSString *guestID) {
    Class userClass = FindClass(@[
        @"GoogleAdsSDK.MBUser",
        @"_TtC12GoogleAdsSDK6MBUser",
        @"MBUser"
    ]);
    if (!userClass) return nil;
    id user = [[userClass alloc] init];
    if (!user) return nil;

    NSString *suffix = guestID.length > 8 ? [guestID substringFromIndex:guestID.length - 8] : guestID;
    NSString *username = [NSString stringWithFormat:@"guest_%@", suffix ?: @"user"];
    NSString *nickname = [NSString stringWithFormat:@"Guest %@", suffix ?: @"User"];
    SafeSet(user, @"uid", @(StableNumericID(guestID)));
    SafeSet(user, @"username", username);
    SafeSet(user, @"nickname", nickname);
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
    if (existing && !objc_getAssociatedObject(existing, kGuestMarkerKey)) return YES;

    id guest = existing ?: CreateGuestUser(guestID);
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

static NSString *FirebaseErrorMessage(NSData *data) {
    if (!data.length) return @"unknown Firebase error";
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![parsed isKindOfClass:NSDictionary.class]) return @"invalid Firebase response";
    NSDictionary *error = [parsed[@"error"] isKindOfClass:NSDictionary.class] ? parsed[@"error"] : nil;
    NSString *message = [error[@"message"] isKindOfClass:NSString.class] ? error[@"message"] : nil;
    return message.length ? message : @"Firebase rejected the guest request";
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
        UIViewController *login = gLoginController;
        if (!login || !HasCachedGuest()) return;
        id manager = ResolveUserManager();
        if (manager && !InjectGuestIntoManager(manager)) {
            ShowGuestStatus(login, @"Guest identity was created, but MovieBox could not attach it to MBUserManager.", YES);
            return;
        }

        [[NSNotificationCenter defaultCenter] postNotificationName:kUserChangedNotification
                                                            object:nil
                                                          userInfo:@{ @"guest": @YES,
                                                                      @"user_id": KeychainRead(kGuestUserAccount) ?: @"" }];

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
            ShowGuestStatus(login, @"Guest identity is ready, but the main MovieBox controller could not be created.", YES);
            return;
        }
        [UIView performWithoutAnimation:^{
            window.rootViewController = main;
            [window makeKeyAndVisible];
            [window layoutIfNeeded];
        }];
    });
}

static void PersistFirebaseGuest(NSString *guestID, NSString *idToken, NSString *refreshToken) {
    if (!guestID.length || !idToken.length || !refreshToken.length) return;
    KeychainWrite(kGuestUserAccount, guestID);
    KeychainWrite(kAccessAccount, idToken);
    KeychainWrite(kRefreshAccount, refreshToken);
    gBootstrapFinished = YES;
    id manager = ResolveUserManager();
    if (manager) InjectGuestIntoManager(manager);
    RoutePastLogin();
}

static void FirebaseAnonymousSignUp(NSString *apiKey) {
    NSString *urlString = [NSString stringWithFormat:@"https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=%@", apiKey];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 20.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [@"{\"returnSecureToken\":true}" dataUsingEncoding:NSUTF8StringEncoding];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (error || ![http isKindOfClass:NSHTTPURLResponse.class] || http.statusCode < 200 || http.statusCode >= 300) {
            NSString *reason = error.localizedDescription ?: FirebaseErrorMessage(data);
            dispatch_async(dispatch_get_main_queue(), ^{
                UIViewController *login = gLoginController;
                if (login) ShowGuestStatus(login,
                    [NSString stringWithFormat:@"Guest account setup failed:\n%@\n\nNo code is required. The 8-digit MovieBox code is only for device pairing.", reason], YES);
            });
            gBootstrapStarted = NO;
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *guestID = [json[@"localId"] isKindOfClass:NSString.class] ? json[@"localId"] : nil;
        NSString *idToken = [json[@"idToken"] isKindOfClass:NSString.class] ? json[@"idToken"] : nil;
        NSString *refresh = [json[@"refreshToken"] isKindOfClass:NSString.class] ? json[@"refreshToken"] : nil;
        if (!guestID.length || !idToken.length || !refresh.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIViewController *login = gLoginController;
                if (login) ShowGuestStatus(login, @"Guest account setup failed: Firebase returned an incomplete session.", YES);
            });
            gBootstrapStarted = NO;
            return;
        }
        PersistFirebaseGuest(guestID, idToken, refresh);
    }] resume];
}

static NSString *FormEncode(NSString *value) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"];
    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static void FirebaseRefresh(NSString *apiKey, NSString *refreshToken) {
    NSString *urlString = [NSString stringWithFormat:@"https://securetoken.googleapis.com/v1/token?key=%@", apiKey];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 20.0;
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    NSString *form = [NSString stringWithFormat:@"grant_type=refresh_token&refresh_token=%@", FormEncode(refreshToken)];
    request.HTTPBody = [form dataUsingEncoding:NSUTF8StringEncoding];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (error || ![http isKindOfClass:NSHTTPURLResponse.class] || http.statusCode < 200 || http.statusCode >= 300) {
            NSString *reason = error.localizedDescription ?: FirebaseErrorMessage(data);
            dispatch_async(dispatch_get_main_queue(), ^{
                UIViewController *login = gLoginController;
                if (login) ShowGuestStatus(login, [NSString stringWithFormat:@"Saved guest session could not refresh:\n%@", reason], YES);
            });
            gBootstrapStarted = NO;
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *guestID = [json[@"user_id"] isKindOfClass:NSString.class] ? json[@"user_id"] : KeychainRead(kGuestUserAccount);
        NSString *idToken = [json[@"id_token"] isKindOfClass:NSString.class] ? json[@"id_token"] : nil;
        NSString *refresh = [json[@"refresh_token"] isKindOfClass:NSString.class] ? json[@"refresh_token"] : nil;
        if (guestID.length && idToken.length && refresh.length) PersistFirebaseGuest(guestID, idToken, refresh);
        gBootstrapStarted = NO;
    }] resume];
}

static void EnsureFirebaseGuest(void) {
    if (gBootstrapStarted || gBootstrapFinished) return;
    gBootstrapStarted = YES;
    StableInstallID();

    NSString *apiKey = FirebaseAPIKey();
    if (!apiKey.length) {
        UIViewController *login = gLoginController;
        if (login) ShowGuestStatus(login, @"Guest account setup failed: GoogleService-Info.plist has no Firebase API key.", YES);
        gBootstrapStarted = NO;
        return;
    }

    NSString *guestID = KeychainRead(kGuestUserAccount);
    NSString *refresh = KeychainRead(kRefreshAccount);
    if (guestID.length) {
        id manager = ResolveUserManager();
        if (manager) InjectGuestIntoManager(manager);
        if (refresh.length) FirebaseRefresh(apiKey, refresh);
        else {
            UIViewController *login = gLoginController;
            if (login) ShowGuestStatus(login, @"Saved guest identity exists but its refresh token is missing.", YES);
            gBootstrapStarted = NO;
        }
        return;
    }

    UIViewController *login = gLoginController;
    if (login) ShowGuestStatus(login, @"Creating your persistent guest account…", NO);
    FirebaseAnonymousSignUp(apiKey);
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
    if (gWatchdogTicks++ >= 80) return;
    HookUserManager();
    ResolveUserManager();

    UIWindow *window = KeyWindow();
    UIViewController *visible = VisibleController(window.rootViewController);
    if (visible && IsLoginController(visible)) {
        gLoginController = visible;
        if (HasCachedGuest()) {
            ShowGuestStatus(visible, @"Restoring your persistent guest account…", NO);
        } else {
            ShowGuestStatus(visible, @"Creating your persistent guest account…", NO);
        }
        EnsureFirebaseGuest();
    }

    if (!gBootstrapFinished || (visible && IsLoginController(visible))) {
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
