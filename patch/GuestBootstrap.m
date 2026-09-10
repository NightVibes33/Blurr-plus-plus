#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>

static NSString *const kService = @"com.xd.mbp31.persistent-guest";
static NSString *const kInstallAccount = @"install-id";
static NSString *const kGuestUserAccount = @"firebase-guest-user-id";
static NSString *const kAccessAccount = @"firebase-id-token";
static NSString *const kRefreshAccount = @"firebase-refresh-token";
static NSString *const kUserChangedNotification = @"MBUserStatusChangedNotification";
static NSInteger const kOverlayTag = 0x4D425047;

static const void *kOrigDidAppearKey = &kOrigDidAppearKey;
static const void *kOrigAppFirstLoadKey = &kOrigAppFirstLoadKey;
static const void *kGuestMarkerKey = &kGuestMarkerKey;
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
    return [name containsString:@"MBLoginBaseViewController"] ||
           [name containsString:@"MBCodeLoginViewController"] ||
           [name containsString:@"MBInvitationCodeLoginController"] ||
           [name containsString:@"TVCodeLoginController"];
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
    if (!userClass) {
        NSLog(@"[MBPGuestBootstrap] MBUser class not found");
        return nil;
    }

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
    if (!userIvar) {
        NSLog(@"[MBPGuestBootstrap] MBUserManager.user ivar not found");
        return NO;
    }

    id existing = object_getIvar(manager, userIvar);
    if (existing && !objc_getAssociatedObject(existing, kGuestMarkerKey)) {
        return YES; // Preserve a legitimate MovieBox user.
    }

    id guest = existing ?: CreateGuestUser(guestID);
    if (!guest) return NO;
    if (!existing) object_setIvar(manager, userIvar, guest);

    [[NSUserDefaults standardUserDefaults] setObject:guestID forKey:@"MBPGuestUserID"];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"MBPGuestBootstrapComplete"];
    NSLog(@"[MBPGuestBootstrap] active Firebase guest %@", guestID);
    return YES;
}

static UIWindow *WindowForController(UIViewController *vc) {
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

static void RoutePastLogin(UIViewController *loginVC) {
    if (!loginVC || !HasCachedGuest()) return;
    if (gUserManager) InjectGuestIntoManager(gUserManager);

    [[NSNotificationCenter defaultCenter] postNotificationName:kUserChangedNotification
                                                        object:nil
                                                      userInfo:@{ @"guest": @YES,
                                                                  @"user_id": KeychainRead(kGuestUserAccount) ?: @"" }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!loginVC.viewIfLoaded.window) return;
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
        UIViewController *main = CreateMainController();
        if (window && main) {
            [UIView performWithoutAnimation:^{
                window.rootViewController = main;
                [window makeKeyAndVisible];
                [window layoutIfNeeded];
            }];
        }
    });
}

static void ShowGuestStatus(UIViewController *vc, NSString *message, BOOL failed) {
    if (!vc || !vc.view) return;
    dispatch_async(dispatch_get_main_queue(), ^{
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

static void PersistFirebaseGuest(NSString *guestID, NSString *idToken, NSString *refreshToken) {
    if (!guestID.length || !idToken.length || !refreshToken.length) return;
    KeychainWrite(kGuestUserAccount, guestID);
    KeychainWrite(kAccessAccount, idToken);
    KeychainWrite(kRefreshAccount, refreshToken);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (gUserManager) InjectGuestIntoManager(gUserManager);
        UIViewController *login = gLoginController;
        if (login) RoutePastLogin(login);
    });
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
            NSLog(@"[MBPGuestBootstrap] Firebase anonymous sign-up failed: %@", reason);
            UIViewController *login = gLoginController;
            if (login) ShowGuestStatus(login,
                [NSString stringWithFormat:@"Guest account setup failed: %@\n\nThe 8-digit code is a device-pairing code and is not the Gmail/invitation code.", reason], YES);
            gBootstrapStarted = NO;
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *guestID = [json[@"localId"] isKindOfClass:NSString.class] ? json[@"localId"] : nil;
        NSString *idToken = [json[@"idToken"] isKindOfClass:NSString.class] ? json[@"idToken"] : nil;
        NSString *refresh = [json[@"refreshToken"] isKindOfClass:NSString.class] ? json[@"refreshToken"] : nil;
        if (!guestID.length || !idToken.length || !refresh.length) {
            UIViewController *login = gLoginController;
            if (login) ShowGuestStatus(login, @"Guest account setup failed: Firebase returned an incomplete session.", YES);
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
            NSLog(@"[MBPGuestBootstrap] Firebase refresh failed: %@", error.localizedDescription ?: FirebaseErrorMessage(data));
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
    if (gBootstrapStarted) return;
    gBootstrapStarted = YES;
    StableInstallID();

    NSString *apiKey = FirebaseAPIKey();
    if (!apiKey.length) {
        UIViewController *login = gLoginController;
        if (login) ShowGuestStatus(login, @"Guest account setup failed: Firebase API key is missing from GoogleService-Info.plist.", YES);
        gBootstrapStarted = NO;
        return;
    }

    NSString *guestID = KeychainRead(kGuestUserAccount);
    NSString *refresh = KeychainRead(kRefreshAccount);
    if (guestID.length) {
        if (gUserManager) InjectGuestIntoManager(gUserManager);
        UIViewController *login = gLoginController;
        if (login) RoutePastLogin(login);
        if (refresh.length) FirebaseRefresh(apiKey, refresh);
        else gBootstrapStarted = NO;
        return;
    }

    UIViewController *login = gLoginController;
    if (login) ShowGuestStatus(login, @"Creating your persistent guest account…", NO);
    FirebaseAnonymousSignUp(apiKey);
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
        RoutePastLogin((UIViewController *)self);
    } else {
        ShowGuestStatus((UIViewController *)self, @"Creating your persistent guest account…", NO);
    }
    EnsureFirebaseGuest();
}

static void UserManagerAppFirstLoad(id self, SEL _cmd) {
    NSValue *stored = objc_getAssociatedObject((id)[self class], kOrigAppFirstLoadKey);
    IMP original = stored ? [stored pointerValue] : NULL;
    if (original && original != (IMP)UserManagerAppFirstLoad) {
        ((void (*)(id, SEL))original)(self, _cmd);
    }
    gUserManager = self;
    if (!ManagerAlreadyHasUser(self) && HasCachedGuest()) InjectGuestIntoManager(self);
    EnsureFirebaseGuest();
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

    SEL selector = NSSelectorFromString(@"appFirstLoad");
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    IMP original = method_getImplementation(method);
    if (!original) return NO;
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
        BOOL manager = HookUserManager();
        BOOL login = HookLoginClasses();
        if ((manager && login) || attempts >= 120) {
            retry = nil;
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), retry);
    };
    dispatch_async(dispatch_get_main_queue(), retry);
}

__attribute__((constructor)) static void GuestBootstrapInit(void) {
    @autoreleasepool {
        StableInstallID();
        // Install synchronously so MBUserManager.appFirstLoad cannot beat the hook.
        InstallHooks();
    }
}
