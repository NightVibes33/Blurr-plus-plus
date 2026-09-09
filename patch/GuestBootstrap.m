#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <objc/message.h>

static IMP gInvLoad = NULL;
static IMP gInvAppear = NULL;
static IMP gCodeLoad = NULL;
static IMP gCodeAppear = NULL;

static NSString *const kGuestService = @"com.xd.mbp31.persistent-guest";
static NSString *const kGuestAccount = @"install-id";
static NSString *const kGuestDefaultsKey = @"MBPStableGuestInstallID";

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
        if (existing.length > 0) return existing;
    } else if (result) {
        CFRelease(result);
    }

    NSString *generated = [NSUUID UUID].UUIDString.lowercaseString;
    NSData *data = [generated dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *item = [MBPKeychainIdentityQuery() mutableCopy];
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    item[(__bridge id)kSecValueData] = data;

    SecItemDelete((__bridge CFDictionaryRef)MBPKeychainIdentityQuery());
    OSStatus addStatus = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    if (addStatus != errSecSuccess && addStatus != errSecDuplicateItem) {
        NSLog(@"[MBPGuestBootstrap] Keychain save failed: %d", (int)addStatus);
    }
    return generated;
}

static void MBPPersistIdentity(void) {
    NSString *installID = MBPStableInstallID();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:installID forKey:kGuestDefaultsKey];
    [defaults setBool:YES forKey:@"MBPPersistentGuestEnabled"];
}

static void MBPBypassLoginController(UIViewController *vc) {
    if (!vc) return;
    MBPPersistIdentity();
    vc.view.hidden = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        SEL close = NSSelectorFromString(@"close");
        SEL closeController = NSSelectorFromString(@"closeContrller");
        if ([vc respondsToSelector:close]) {
            ((void (*)(id, SEL))objc_msgSend)(vc, close);
        } else if ([vc respondsToSelector:closeController]) {
            ((void (*)(id, SEL))objc_msgSend)(vc, closeController);
        }

        UIViewController *presenter = vc.presentingViewController;
        if (presenter) {
            [presenter dismissViewControllerAnimated:NO completion:nil];
            return;
        }

        UINavigationController *nav = vc.navigationController;
        if (nav && nav.viewControllers.count > 1 && nav.topViewController == vc) {
            [nav popViewControllerAnimated:NO];
        }
    });
}

static void InvLoad(id self, SEL _cmd) {
    if (gInvLoad) ((void (*)(id, SEL))gInvLoad)(self, _cmd);
    MBPBypassLoginController((UIViewController *)self);
}

static void InvAppear(id self, SEL _cmd, BOOL animated) {
    if (gInvAppear) ((void (*)(id, SEL, BOOL))gInvAppear)(self, _cmd, animated);
    MBPBypassLoginController((UIViewController *)self);
}

static void CodeLoad(id self, SEL _cmd) {
    if (gCodeLoad) ((void (*)(id, SEL))gCodeLoad)(self, _cmd);
    MBPBypassLoginController((UIViewController *)self);
}

static void CodeAppear(id self, SEL _cmd, BOOL animated) {
    if (gCodeAppear) ((void (*)(id, SEL, BOOL))gCodeAppear)(self, _cmd, animated);
    MBPBypassLoginController((UIViewController *)self);
}

static Class MBPFindClass(NSArray<NSString *> *names) {
    for (NSString *name in names) {
        Class cls = NSClassFromString(name);
        if (!cls) cls = objc_getClass(name.UTF8String);
        if (cls) return cls;
    }
    return Nil;
}

static void MBPHookMethod(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    IMP current = method_getImplementation(method);
    if (current == replacement) return;
    if (*original == NULL) *original = current;
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
}

static void MBPInstallHooks(void) {
    MBPPersistIdentity();

    Class invitation = MBPFindClass(@[
        @"GoogleAdsSDK.MBInvitationCodeLoginController",
        @"_TtC12GoogleAdsSDK31MBInvitationCodeLoginController",
        @"MBInvitationCodeLoginController"
    ]);
    MBPHookMethod(invitation, @selector(viewDidLoad), (IMP)InvLoad, &gInvLoad);
    MBPHookMethod(invitation, @selector(viewDidAppear:), (IMP)InvAppear, &gInvAppear);

    Class code = MBPFindClass(@[
        @"GoogleAdsSDK.MBCodeLoginViewController",
        @"_TtC12GoogleAdsSDK25MBCodeLoginViewController",
        @"MBCodeLoginViewController"
    ]);
    MBPHookMethod(code, @selector(viewDidLoad), (IMP)CodeLoad, &gCodeLoad);
    MBPHookMethod(code, @selector(viewDidAppear:), (IMP)CodeAppear, &gCodeAppear);
}

__attribute__((constructor))
static void MBPGuestBootstrapInit(void) {
    MBPPersistIdentity();
    dispatch_async(dispatch_get_main_queue(), ^{
        MBPInstallHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            MBPInstallHooks();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            MBPInstallHooks();
        });
    });
}
