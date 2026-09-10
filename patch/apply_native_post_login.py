#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: apply_native_post_login.py INPUT OUTPUT")

src = Path(sys.argv[1]).read_text()
start_marker = "static void RoutePastLogin(void) {"
end_marker = "\nstatic void PersistGuestResponse(NSDictionary *json) {"
start = src.find(start_marker)
end = src.find(end_marker, start)
if start < 0 or end < 0:
    raise SystemExit("RoutePastLogin markers not found")

replacement = r'''static void FallbackRoutePastLogin(UIViewController *login) {
    if (gDidRouteOnce || !login) return;

    if (login.presentingViewController) {
        gDidRouteOnce = YES;
        [login.presentingViewController dismissViewControllerAnimated:NO completion:nil];
        return;
    }

    UINavigationController *nav = login.navigationController;
    if (nav && nav.topViewController == login && nav.viewControllers.count > 1) {
        gDidRouteOnce = YES;
        [nav popViewControllerAnimated:NO];
        return;
    }

    UIWindow *window = login.viewIfLoaded.window ?: KeyWindow();
    UIViewController *main = CreateMainController();
    if (!window || !main) {
        gState = GuestStateTerminalFailure;
        ShowGuestStatus(login, @"Guest account is ready, but MovieBox could not complete its post-login transition.", YES);
        return;
    }

    gDidRouteOnce = YES;
    [UIView performWithoutAnimation:^{
        window.rootViewController = main;
        [window makeKeyAndVisible];
        [window layoutIfNeeded];
    }];
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

        // Let the app see the same user-change event its normal successful login path uses.
        [[NSNotificationCenter defaultCenter] postNotificationName:kUserChangedNotification
                                                            object:nil
                                                          userInfo:@{ @"guest": @YES,
                                                                      @"user_id": KeychainRead(kGuestUserAccount) ?: @"" }];

        // Code-login controllers expose the app's own post-login completion routine.
        // Call it when available so coordinator/network/bootstrap setup runs normally.
        SEL complete = NSSelectorFromString(@"didCompleteLogin");
        if ([login respondsToSelector:complete]) {
            ((void (*)(id, SEL))objc_msgSend)(login, complete);
        }

        // Do not immediately replace the root. Give MovieBox's notification/coordinator
        // path a chance to transition and initialize its network stack first.
        __weak UIViewController *weakLogin = login;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gDidRouteOnce) return;
            UIWindow *window = KeyWindow();
            UIViewController *visible = VisibleController(window.rootViewController);
            if (visible && !IsLoginController(visible)) {
                gDidRouteOnce = YES;
                return;
            }
            FallbackRoutePastLogin(weakLogin ?: gLoginController);
        });
    });
}
'''

out = src[:start] + replacement + src[end:]
Path(sys.argv[2]).write_text(out)
print("patched RoutePastLogin to prefer MovieBox native transition")
