#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString * const kMBPInstallService = @"com.xd.mbp31.persistent-access";
static NSString * const kMBPInstallAccount = @"installation-id";
static NSString * const kMBPInstallDefaultsKey = @"MBP_PersistentInstallID";

static NSString *MBPLoadKeychainValue(void) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kMBPInstallService,
        (__bridge id)kSecAttrAccount: kMBPInstallAccount,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) return nil;
    NSData *data = CFBridgingRelease(result);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSString *MBPStableInstallID(void) {
    NSString *existing = MBPLoadKeychainValue();
    if (existing.length > 0) {
        [[NSUserDefaults standardUserDefaults] setObject:existing forKey:kMBPInstallDefaultsKey];
        return existing;
    }

    NSString *value = NSUUID.UUID.UUIDString;
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *item = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kMBPInstallService,
        (__bridge id)kSecAttrAccount: kMBPInstallAccount,
        (__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    };
    SecItemDelete((__bridge CFDictionaryRef)@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kMBPInstallService,
        (__bridge id)kSecAttrAccount: kMBPInstallAccount
    });
    SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:kMBPInstallDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    return value;
}

static IMP gOriginalInvitationViewDidLoad = NULL;
static IMP gSuperInvitationViewDidAppear = NULL;
static IMP gOriginalAppFirstLoad = NULL;

static void MBPCloseInvitationController(id self) {
    SEL closeSel = NSSelectorFromString(@"close");
    if ([self respondsToSelector:closeSel]) {
        ((void(*)(id,SEL))objc_msgSend)(self, closeSel);
        return;
    }

    if ([self isKindOfClass:UIViewController.class]) {
        UIViewController *vc = (UIViewController *)self;
        if (vc.presentingViewController) {
            [vc dismissViewControllerAnimated:NO completion:nil];
        } else if (vc.navigationController && vc.navigationController.viewControllers.count > 1) {
            [vc.navigationController popViewControllerAnimated:NO];
        }
    }
}

static void MBPInvitationViewDidLoad(id self, SEL _cmd) {
    if (gOriginalInvitationViewDidLoad) {
        ((void(*)(id,SEL))gOriginalInvitationViewDidLoad)(self, _cmd);
    }
    MBPStableInstallID();
}

static void MBPInvitationViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gSuperInvitationViewDidAppear) {
        ((void(*)(id,SEL,BOOL))gSuperInvitationViewDidAppear)(self, _cmd, animated);
    }
    MBPStableInstallID();
    dispatch_async(dispatch_get_main_queue(), ^{
        MBPCloseInvitationController(self);
    });
}

static void MBPAppFirstLoad(id self, SEL _cmd) {
    MBPStableInstallID();
    if (gOriginalAppFirstLoad) {
        ((void(*)(id,SEL))gOriginalAppFirstLoad)(self, _cmd);
    }
}

static BOOL MBPHookOnce(void) {
    Class invitation = NSClassFromString(@"GoogleAdsSDK.MBInvitationCodeLoginController");
    if (!invitation) invitation = NSClassFromString(@"_TtC12GoogleAdsSDK31MBInvitationCodeLoginController");

    Class manager = NSClassFromString(@"GoogleAdsSDK.MBUserManager");
    if (!manager) manager = NSClassFromString(@"_TtC12GoogleAdsSDK13MBUserManager");

    BOOL hooked = NO;

    if (manager) {
        Method appFirstLoad = class_getInstanceMethod(manager, NSSelectorFromString(@"appFirstLoad"));
        if (appFirstLoad) {
            IMP current = method_getImplementation(appFirstLoad);
            if (current != (IMP)MBPAppFirstLoad) {
                gOriginalAppFirstLoad = current;
                method_setImplementation(appFirstLoad, (IMP)MBPAppFirstLoad);
            }
            hooked = YES;
        }
    }

    if (invitation) {
        Method didLoad = class_getInstanceMethod(invitation, @selector(viewDidLoad));
        if (didLoad) {
            IMP current = method_getImplementation(didLoad);
            if (current != (IMP)MBPInvitationViewDidLoad) {
                gOriginalInvitationViewDidLoad = current;
                method_setImplementation(didLoad, (IMP)MBPInvitationViewDidLoad);
            }
        }

        SEL appearedSel = @selector(viewDidAppear:);
        Method inherited = class_getInstanceMethod(invitation, appearedSel);
        if (inherited) {
            gSuperInvitationViewDidAppear = method_getImplementation(inherited);
            const char *types = method_getTypeEncoding(inherited);
            class_addMethod(invitation, appearedSel, (IMP)MBPInvitationViewDidAppear, types);
        }
        hooked = YES;
    }

    return hooked;
}

__attribute__((constructor)) static void MBPPersistentAccessInit(void) {
    @autoreleasepool {
        MBPStableInstallID();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (MBPHookOnce()) return;
            __block NSInteger attempts = 0;
            __block void (^retry)(void) = nil;
            retry = ^{
                attempts++;
                if (MBPHookOnce() || attempts >= 80) {
                    retry = nil;
                    return;
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)), dispatch_get_main_queue(), retry);
            };
            retry();
        });
    }
}
