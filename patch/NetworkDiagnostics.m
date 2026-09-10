#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static const void *kNetOriginalResumeKey = &kNetOriginalResumeKey;
static NSInteger const kNetOverlayTag = 0x4D42504E;
static NSMutableArray<NSString *> *gNetLines;
static NSInteger gObservedRequests = 0;

static UIWindow *NetKeyWindow(void) {
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

static void NetPublish(NSString *line) {
    if (!line.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gNetLines) gNetLines = [NSMutableArray array];
        [gNetLines addObject:line];
        while (gNetLines.count > 4) [gNetLines removeObjectAtIndex:0];

        UIWindow *window = NetKeyWindow();
        if (!window) return;
        UILabel *label = (UILabel *)[window viewWithTag:kNetOverlayTag];
        if (![label isKindOfClass:UILabel.class]) {
            label = [[UILabel alloc] initWithFrame:CGRectZero];
            label.tag = kNetOverlayTag;
            label.translatesAutoresizingMaskIntoConstraints = NO;
            label.numberOfLines = 0;
            label.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightMedium];
            label.textColor = UIColor.whiteColor;
            label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
            label.layer.cornerRadius = 8;
            label.layer.masksToBounds = YES;
            label.userInteractionEnabled = NO;
            [window addSubview:label];
            [NSLayoutConstraint activateConstraints:@[
                [label.leadingAnchor constraintEqualToAnchor:window.leadingAnchor constant:8],
                [label.trailingAnchor constraintEqualToAnchor:window.trailingAnchor constant:-8],
                [label.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-8]
            ]];
        }
        label.text = [@" NET DIAGNOSTIC\n" stringByAppendingString:[gNetLines componentsJoinedByString:@"\n"]];
        [window bringSubviewToFront:label];
    });
}

static BOOL IsInterestingRequest(NSURLRequest *request) {
    NSString *host = request.URL.host.lowercaseString ?: @"";
    if (!host.length) return NO;
    if ([host containsString:@"movieboxpro-guest-auth.lovable.app"]) return NO;
    return [request.URL.scheme.lowercaseString hasPrefix:@"http"];
}

static NSString *RequestAction(NSURLRequest *request) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name.lowercaseString isEqualToString:@"action"] && item.value.length) return item.value;
    }

    NSData *body = request.HTTPBody;
    if (!body.length) return nil;
    NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    if (!text.length) return nil;

    NSRange actionRange = [text rangeOfString:@"action="];
    if (actionRange.location != NSNotFound) {
        NSUInteger start = NSMaxRange(actionRange);
        NSRange rest = NSMakeRange(start, text.length - start);
        NSRange amp = [text rangeOfString:@"&" options:0 range:rest];
        NSUInteger end = amp.location == NSNotFound ? text.length : amp.location;
        NSString *value = [text substringWithRange:NSMakeRange(start, end - start)];
        return [value stringByRemovingPercentEncoding] ?: value;
    }

    NSData *jsonData = [text dataUsingEncoding:NSUTF8StringEncoding];
    id json = jsonData ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil] : nil;
    if ([json isKindOfClass:NSDictionary.class]) {
        id action = ((NSDictionary *)json)[@"action"];
        if ([action isKindOfClass:NSString.class] && [action length]) return action;
    }
    return nil;
}

static BOOL RequestHasLegacyCredential(NSURLRequest *request) {
    NSDictionary<NSString *, NSString *> *headers = request.allHTTPHeaderFields ?: @{};
    for (NSString *key in headers) {
        NSString *lower = key.lowercaseString;
        if ([lower containsString:@"authorization"] ||
            [lower containsString:@"credential"] ||
            [lower containsString:@"session"] ||
            [lower containsString:@"token"]) {
            NSString *value = headers[key];
            if (value.length) return YES;
        }
    }

    NSData *body = request.HTTPBody;
    if (body.length) {
        NSString *text = [[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] lowercaseString];
        if ([text containsString:@"session_credential"] ||
            [text containsString:@"auth_token"] ||
            [text containsString:@"user_token"] ||
            [text containsString:@"sessionkey"] ||
            [text containsString:@"session_key"]) return YES;
    }
    return NO;
}

static NSString *TaskBrief(NSURLSessionTask *task) {
    NSURLRequest *request = task.currentRequest ?: task.originalRequest;
    if (!request) return @"request=?";
    NSString *host = request.URL.host ?: @"?";
    NSString *path = request.URL.path.length ? request.URL.path : @"/";
    NSString *action = RequestAction(request);
    NSString *credential = RequestHasLegacyCredential(request) ? @"cred=YES" : @"cred=NO";
    if (action.length) return [NSString stringWithFormat:@"%@%@ action=%@ %@", host, path, action, credential];
    return [NSString stringWithFormat:@"%@%@ %@", host, path, credential];
}

static IMP OriginalResumeIMPForObject(id object) {
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        NSValue *value = objc_getAssociatedObject((id)cls, kNetOriginalResumeKey);
        if (value) return [value pointerValue];
    }
    return NULL;
}

static void ObserveCompletion(NSURLSessionTask *task, NSString *brief, NSInteger attempt) {
    if (!task || attempt > 80) return;
    if (task.state == NSURLSessionTaskStateCompleted) {
        NSInteger status = 0;
        if ([task.response isKindOfClass:NSHTTPURLResponse.class]) status = ((NSHTTPURLResponse *)task.response).statusCode;
        NSString *err = task.error ? [NSString stringWithFormat:@" err=%ld", (long)task.error.code] : @"";
        NetPublish([NSString stringWithFormat:@"RESP %ld %@%@", (long)status, brief, err]);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ObserveCompletion(task, brief, attempt + 1);
    });
}

static void NetResume(id self, SEL _cmd) {
    NSURLSessionTask *task = [self isKindOfClass:NSURLSessionTask.class] ? (NSURLSessionTask *)self : nil;
    NSURLRequest *request = task.currentRequest ?: task.originalRequest;
    NSString *brief = nil;
    if (request && IsInterestingRequest(request)) {
        gObservedRequests += 1;
        brief = TaskBrief(task);
        NetPublish([@"REQ  " stringByAppendingString:brief]);
    }

    IMP original = OriginalResumeIMPForObject(self);
    if (original && original != (IMP)NetResume) {
        ((void (*)(id, SEL))original)(self, _cmd);
    }

    if (brief.length) ObserveCompletion(task, brief, 0);
}

static BOOL ClassDefinesSelector(Class cls, SEL selector, Method *outMethod) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            if (outMethod) *outMethod = methods[i];
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

static void HookResumeMethods(void) {
    SEL selector = @selector(resume);
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    count = objc_getClassList(classes, count);

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        Class superCls = class_getSuperclass(cls);
        if (!superCls) continue;
        if (![cls isSubclassOfClass:NSURLSessionTask.class]) continue;
        Method method = NULL;
        if (!ClassDefinesSelector(cls, selector, &method) || !method) continue;
        if (objc_getAssociatedObject((id)cls, kNetOriginalResumeKey)) continue;
        IMP original = method_getImplementation(method);
        if (!original || original == (IMP)NetResume) continue;
        objc_setAssociatedObject((id)cls, kNetOriginalResumeKey, [NSValue valueWithPointer:original], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        method_setImplementation(method, (IMP)NetResume);
    }
    free(classes);
}

__attribute__((constructor)) static void NetworkDiagnosticsInit(void) {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.50 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            HookResumeMethods();
            NetPublish(@"observer active");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (gObservedRequests == 0) NetPublish(@"NO HTTP(S) request observed after startup");
            });
        });
    }
}
