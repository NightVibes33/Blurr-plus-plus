#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: apply_public_guest_mode.py <input.m> <output.m>")

src = Path(sys.argv[1]).read_text()

# The owned guest identity belongs to our backend, not MovieBox's legacy account
# namespace.  A fabricated non-zero MovieBox uid makes legacy request code select
# authenticated/session-only paths even though no legacy session exists.  Keep the
# local guest MBUser object, but leave its uid in MBUser's native default state so
# public catalogue/search APIs use their normal anonymous path.
uid_line = '    SafeSet(user, @"uid", @(StableNumericID(guestID)));\n'
if uid_line not in src:
    raise SystemExit("expected synthetic uid assignment not found")
src = src.replace(
    uid_line,
    '    // Owned guest is intentionally anonymous to the legacy MovieBox API.\n'
    '    // Do not assign a fabricated MovieBox uid or legacy session credential.\n',
    1,
)

anchor = 'static void WatchdogTick(void) {'
if anchor not in src:
    raise SystemExit("WatchdogTick anchor not found")

public_mode = r'''
// MovieBoxPro 16.0 MBHomeViewModel exposes a Swift Bool ivar named
// needInvitationCode.  Its verified ABI offset in this build is 0x18 (24).
// Resolve the ivar dynamically first and use the verified offset only as fallback.
// This affects the local UI/public-content gate only; it does not create a legacy
// account, session, VIP state, or authorization.
static const void *kHomeInitHookKey = &kHomeInitHookKey;

static void ForceHomePublicMode(id viewModel) {
    if (!viewModel) return;

    Ivar gateIvar = class_getInstanceVariable([viewModel class], "needInvitationCode");
    ptrdiff_t offset = gateIvar ? ivar_getOffset(gateIvar) : (ptrdiff_t)24;
    size_t size = class_getInstanceSize([viewModel class]);
    if (offset < 0 || (size_t)offset >= size) return;

    unsigned char *bytes = (unsigned char *)(__bridge void *)viewModel;
    bytes[offset] = 0;
}

static id HomeViewModelInit(id self, SEL _cmd) {
    NSValue *stored = objc_getAssociatedObject((id)[self class], kHomeInitHookKey);
    IMP original = stored ? [stored pointerValue] : NULL;
    id result = self;
    if (original && original != (IMP)HomeViewModelInit) {
        result = ((id (*)(id, SEL))original)(self, _cmd);
    }

    ForceHomePublicMode(result);

    // The home response may update this gate asynchronously.  Keep the owned guest
    // on the native public catalogue path through initial home bootstrap/refresh.
    __weak id weakResult = result;
    const double delays[] = {0.20, 0.75, 1.50, 3.00, 6.00, 10.00};
    for (unsigned int i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
        double delay = delays[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ForceHomePublicMode(weakResult);
        });
    }
    return result;
}

static BOOL HookHomePublicMode(void) {
    Class cls = FindClass(@[
        @"GoogleAdsSDK.MBHomeViewModel",
        @"_TtC12GoogleAdsSDK15MBHomeViewModel",
        @"MBHomeViewModel"
    ]);
    if (!cls) return NO;
    if (objc_getAssociatedObject((id)cls, kHomeInitHookKey)) return YES;

    SEL selector = @selector(init);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    IMP original = method_getImplementation(method);
    if (!original || original == (IMP)HomeViewModelInit) return NO;

    objc_setAssociatedObject((id)cls, kHomeInitHookKey,
                             [NSValue valueWithPointer:original],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    method_setImplementation(method, (IMP)HomeViewModelInit);
    return YES;
}

'''
src = src.replace(anchor, public_mode + anchor, 1)

# Install early, retry from the existing watchdog in case Swift class realization
# happens after our dylib constructor.
watchdog_body = '''static void WatchdogTick(void) {\n    if (gWatchdogTicks++ >= 120) return;\n\n    HookUserManager();'''
watchdog_repl = '''static void WatchdogTick(void) {\n    if (gWatchdogTicks++ >= 120) return;\n\n    HookHomePublicMode();\n    HookUserManager();'''
if watchdog_body not in src:
    raise SystemExit("WatchdogTick body pattern not found")
src = src.replace(watchdog_body, watchdog_repl, 1)

constructor_body = '''        StableInstallID();\n        HookUserManager();'''
constructor_repl = '''        StableInstallID();\n        HookHomePublicMode();\n        HookUserManager();'''
if constructor_body not in src:
    raise SystemExit("constructor pattern not found")
src = src.replace(constructor_body, constructor_repl, 1)

Path(sys.argv[2]).write_text(src)
print("patched owned guest for native public content mode")
