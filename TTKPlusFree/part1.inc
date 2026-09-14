#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString * const kTTKTag = @"TTKPlusFree";
static const NSInteger kTTKDownloadTag = 0x54544B44;
static NSMutableDictionary<NSString *, NSValue *> *gOriginals;
static NSMutableSet<NSString *> *gInstalled;

static NSArray<NSString *> *TTKFeatureKeys(void) {
    return @[@"TTKPlus_Enabled", @"TTKPlus_ShowFollowBadge", @"TTKPlus_ShowVideoCount",
             @"TTKPlus_AvatarLongPress", @"TTKPlus_ClearDisplayEnabled", @"TTKPlus_AdBlock",
             @"TTKPlus_CountryPill", @"TTKPlus_GridDate", @"TTKPlus_DownloadButton",
             @"TTKPlus_StoryEye", @"TTKPlus_MsgEye", @"TTKPlus_LiveAutoClick", @"TTKPlus_Bio",
             @"TTKPlus_AnonymousProfileView", @"TTKPlus_LoopMode", @"TTKPlus_DisableWarnings",
             @"TTKPlus_SkipRecommendations", @"TTKPlus_FollowConfirmation",
             @"TTKPlus_LikeConfirmation", @"TTKPlus_LikeCommentConfirmation",
             @"TTKPlus_HideFriendsTab", @"TTKPlus_HideCreateTab", @"TTKPlus_HideInboxTab"];
}

static void TTKRegisterDefaults(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *k in TTKFeatureKeys()) d[k] = @YES;
    d[@"TTKPlus_HideFriendsTab"] = @NO;
    d[@"TTKPlus_HideCreateTab"] = @NO;
    d[@"TTKPlus_HideInboxTab"] = @NO;
    [[NSUserDefaults standardUserDefaults] registerDefaults:d];
}

static BOOL TTKOn(NSString *key) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    return [d boolForKey:@"TTKPlus_Enabled"] && [d boolForKey:key];
}

static NSString *TTKHookKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
}

static IMP TTKOriginal(id obj, SEL sel) {
    Class c = object_getClass(obj);
    while (c) {
        NSValue *v = gOriginals[TTKHookKey(c, sel)];
        if (v) return [v pointerValue];
        c = class_getSuperclass(c);
    }
    return NULL;
}

static BOOL TTKClassDirectlyDefines(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { found = YES; break; }
    }
    free(methods);
    return found;
}

static BOOL TTKHookDirect(Class cls, SEL sel, IMP replacement) {
    if (!cls || !sel || !replacement || !TTKClassDirectlyDefines(cls, sel)) return NO;
    NSString *key = TTKHookKey(cls, sel);
    if ([gInstalled containsObject:key]) return YES;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP old = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    if (!old || !types) return NO;
    gOriginals[key] = [NSValue valueWithPointer:old];
    class_replaceMethod(cls, sel, replacement, types);
    [gInstalled addObject:key];
    return YES;
}

static BOOL TTKHookNamed(NSString *name, SEL sel, IMP replacement) {
    Class cls = NSClassFromString(name);
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    NSString *key = TTKHookKey(cls, sel);
    if ([gInstalled containsObject:key]) return YES;
    IMP old = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    if (!old || !types) return NO;
    gOriginals[key] = [NSValue valueWithPointer:old];
    class_replaceMethod(cls, sel, replacement, types);
    [gInstalled addObject:key];
    return YES;
}

static BOOL TTKInterestingClass(Class cls) {
    const char *n = class_getName(cls);
    if (!n) return NO;
    return !strncmp(n,"AWE",3) || !strncmp(n,"TTK",3) || !strncmp(n,"IES",3) ||
           !strncmp(n,"TIKTOK",6) || !strncmp(n,"TIM",3) || !strncmp(n,"BD",2);
}

static id TTKSafeValue(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try { return [obj valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

static NSURL *TTKURLFromValue(id v, NSInteger depth) {
    if (!v || depth > 4) return nil;
    if ([v isKindOfClass:NSURL.class]) return v;
    if ([v isKindOfClass:NSString.class]) {
        NSString *s = v;
        if ([s hasPrefix:@"http://"] || [s hasPrefix:@"https://"]) return [NSURL URLWithString:s];
        return nil;
    }
    if ([v isKindOfClass:NSArray.class]) {
        for (id x in v) { NSURL *u = TTKURLFromValue(x, depth+1); if (u) return u; }
        return nil;
    }
    if ([v isKindOfClass:NSDictionary.class]) {
        NSArray *preferred = @[@"url",@"URL",@"uri",@"downloadUrl",@"downloadURL",@"playUrl",@"playURL",@"urlList",@"URLList"];
        for (NSString *k in preferred) { NSURL *u = TTKURLFromValue(v[k], depth+1); if (u) return u; }
        for (id x in [v allValues]) { NSURL *u = TTKURLFromValue(x, depth+1); if (u) return u; }
        return nil;
    }
    NSArray *keys = @[@"downloadURL",@"downloadUrl",@"playURL",@"playUrl",@"URLList",@"urlList",@"originURL",@"videoURL",@"uri",@"url"];
    for (NSString *k in keys) { NSURL *u = TTKURLFromValue(TTKSafeValue(v,k), depth+1); if (u) return u; }
    return nil;
}

static id TTKFindModel(UIViewController *vc) {
    for (NSString *k in @[@"aweme",@"model",@"item",@"playItem",@"currentAweme",@"awemeModel",@"videoModel"]) {
        id x = TTKSafeValue(vc,k); if (x) return x;
    }
    return nil;
}

static void TTKToast(UIViewController *vc, NSString *text) {
    if (!vc.view.window) return;
    UILabel *l = [[UILabel alloc] init];
    l.text = text; l.textColor = UIColor.whiteColor; l.backgroundColor = [UIColor colorWithWhite:0 alpha:.82];
    l.textAlignment = NSTextAlignmentCenter; l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    l.numberOfLines = 2; l.layer.cornerRadius = 11; l.clipsToBounds = YES;
    l.translatesAutoresizingMaskIntoConstraints = NO; [vc.view addSubview:l];
    [NSLayoutConstraint activateConstraints:@[[l.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
      [l.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor constant:-80],
      [l.widthAnchor constraintLessThanOrEqualToAnchor:vc.view.widthAnchor constant:-40], [l.heightAnchor constraintGreaterThanOrEqualToConstant:40]]];
    [UIView animateWithDuration:.25 delay:1.3 options:0 animations:^{ l.alpha=0; } completion:^(__unused BOOL f){ [l removeFromSuperview]; }];
}
