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
static const void *kOrigDidAppearKey = &kOrigDidAppearKey;
static BOOL gBootstrapStarted = NO;

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
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &result) != errSecSuccess || !result) return nil;
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

static BOOL IsLoginController(id object) {
    if (!object) return NO;
    NSString *name = NSStringFromClass([object class]);
    return [name containsString:@"MBLoginBaseViewController"] ||
           [name containsString:@"MBCodeLoginViewController"] ||
           [name containsString:@"MBInvitationCodeLoginController"] ||
           [name containsString:@"TVCodeLoginController"];
}

static void PersistBootstrapResponse(NSDictionary *json) {
    NSDictionary *user = [json[@"user"] isKindOfClass:NSDictionary.class] ? json[@"user"] : nil;
    NSDictionary *session = [json[@"session"] isKindOfClass:NSDictionary.class] ? json[@"session"] : nil;
    NSString *userID = [user[@"id"] isKindOfClass:NSString.class] ? user[@"id"] : nil;
    NSString *access = [session[@"access_token"] isKindOfClass:NSString.class] ? session[@"access_token"] : nil;
    NSString *refresh = [session[@"refresh_token"] isKindOfClass:NSString.class] ? session[@"refresh_token"] : nil;
    if (!userID.length || !access.length || !refresh.length) return;

    KeychainWrite(kGuestUserAccount, userID);
    KeychainWrite(kAccessAccount, access);
    KeychainWrite(kRefreshAccount, refresh);
    [[NSUserDefaults standardUserDefaults] setObject:userID forKey:@"MBPGuestUserID"];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"MBPGuestBootstrapComplete"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MBPOwnedGuestSessionReadyNotification" object:nil userInfo:@{ @"user_id": userID }];
}

static void BootstrapOwnedGuest(void) {
    if (gBootstrapStarted) return;
    gBootstrapStarted = YES;

    if (KeychainRead(kGuestUserAccount).length && KeychainRead(kAccessAccount).length && KeychainRead(kRefreshAccount).length) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MBPOwnedGuestSessionReadyNotification" object:nil];
        return;
    }

    NSURL *url = BootstrapURL();
    if (!url) {
        NSLog(@"[MBPGuestBootstrap] MBPGuestBootstrapURL is not configured");
        return;
    }

    NSData *body = [NSJSONSerialization dataWithJSONObject:@{ @"install_id": StableInstallID() } options:0 error:nil];
    if (!body) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    request.timeoutInterval = 15.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data.length) return;
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (![http isKindOfClass:NSHTTPURLResponse.class] || http.statusCode < 200 || http.statusCode >= 300) return;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:NSDictionary.class]) return;
        PersistBootstrapResponse(json);
    }] resume];
}

static NSValue *OriginalValue(Class cls) {
    for (Class current = cls; current != Nil; current = class_getSuperclass(current)) {
        NSValue *value = objc_getAssociatedObject((id)current, kOrigDidAppearKey);
        if (value) return value;
    }
    return nil;
}

static void LoginDidAppear(id self, SEL _cmd, BOOL animated) {
    NSValue *stored = OriginalValue([self class]);
    IMP original = stored ? [stored pointerValue] : NULL;
    if (original && original != (IMP)LoginDidAppear) {
        ((void (*)(id, SEL, BOOL))original)(self, _cmd, animated);
    }
    if (IsLoginController(self)) BootstrapOwnedGuest();
}

static BOOL HookClass(Class cls) {
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

static BOOL HookLoginClasses(void) {
    NSArray<NSArray<NSString *> *> *groups = @[
        @[@"GoogleAdsSDK.MBLoginBaseViewController", @"_TtC12GoogleAdsSDK25MBLoginBaseViewController", @"MBLoginBaseViewController"],
        @[@"GoogleAdsSDK.MBCodeLoginViewController", @"_TtC12GoogleAdsSDK25MBCodeLoginViewController", @"MBCodeLoginViewController"],
        @[@"GoogleAdsSDK.MBInvitationCodeLoginController", @"_TtC12GoogleAdsSDK31MBInvitationCodeLoginController", @"MBInvitationCodeLoginController"],
        @[@"GoogleAdsSDK.TVCodeLoginController", @"_TtC12GoogleAdsSDK21TVCodeLoginController", @"TVCodeLoginController"]
    ];
    BOOL found = NO;
    for (NSArray<NSString *> *names in groups) {
        Class cls = Nil;
        for (NSString *name in names) {
            cls = NSClassFromString(name);
            if (!cls) cls = objc_getClass(name.UTF8String);
            if (cls) break;
        }
        if (cls) found |= HookClass(cls);
    }
    return found;
}

static void InstallHooks(void) {
    if (HookLoginClasses()) return;
    __block NSInteger attempts = 0;
    __block void (^retry)(void) = nil;
    retry = ^{
        attempts++;
        if (HookLoginClasses() || attempts >= 100) {
            retry = nil;
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), retry);
    };
    retry();
}

__attribute__((constructor)) static void GuestBootstrapInit(void) {
    @autoreleasepool {
        StableInstallID();
        dispatch_async(dispatch_get_main_queue(), ^{ InstallHooks(); });
    }
}
