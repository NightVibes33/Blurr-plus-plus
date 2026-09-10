#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static const void *kNetOriginalResumeKey = &kNetOriginalResumeKey;
static const void *kNetOriginalDataTaskKey = &kNetOriginalDataTaskKey;
static NSInteger const kNetOverlayTag = 0x4D42504E;
static NSMutableArray<NSString *> *gNetLines;
static NSInteger gObservedRequests = 0;

typedef void (^NetDataCompletion)(NSData *data, NSURLResponse *response, NSError *error);

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

static NSString *NetTruncate(NSString *value, NSUInteger maxLength) {
    if (!value.length) return @"-";
    NSString *flat = [[value stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
                      stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    if (flat.length <= maxLength) return flat;
    return [[flat substringToIndex:maxLength] stringByAppendingString:@"…"];
}

static void NetPublish(NSString *line) {
    if (!line.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gNetLines) gNetLines = [NSMutableArray array];
        [gNetLines addObject:line];
        while (gNetLines.count > 5) [gNetLines removeObjectAtIndex:0];

        UIWindow *window = NetKeyWindow();
        if (!window) return;
        UILabel *label = (UILabel *)[window viewWithTag:kNetOverlayTag];
        if (![label isKindOfClass:UILabel.class]) {
            label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 0, 0)];
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

static NSString *RequestBrief(NSURLRequest *request) {
    if (!request) return @"request=?";
    NSString *host = request.URL.host ?: @"?";
    NSString *path = request.URL.path.length ? request.URL.path : @"/";
    NSString *action = RequestAction(request);
    NSString *credential = RequestHasLegacyCredential(request) ? @"cred=YES" : @"cred=NO";
    if (action.length) return [NSString stringWithFormat:@"%@%@ action=%@ %@", host, path, action, credential];
    return [NSString stringWithFormat:@"%@%@ %@", host, path, credential];
}

static NSString *TaskBrief(NSURLSessionTask *task) {
    return RequestBrief(task.currentRequest ?: task.originalRequest);
}

static NSString *NetScalar(id value) {
    if ([value isKindOfClass:NSString.class]) return NetTruncate((NSString *)value, 100);
    if ([value isKindOfClass:NSNumber.class]) return [(NSNumber *)value stringValue];
    if ([value isKindOfClass:NSNull.class]) return @"null";
    return @"-";
}

static NSString *NetDataShape(id value) {
    if (!value || value == NSNull.null) return @"null";
    if ([value isKindOfClass:NSDictionary.class]) return [NSString stringWithFormat:@"dict(%lu)", (unsigned long)[(NSDictionary *)value count]];
    if ([value isKindOfClass:NSArray.class]) return [NSString stringWithFormat:@"array(%lu)", (unsigned long)[(NSArray *)value count]];
    if ([value isKindOfClass:NSString.class]) return [NSString stringWithFormat:@"string(%lu)", (unsigned long)[(NSString *)value length]];
    if ([value isKindOfClass:NSNumber.class]) return @"number";
    return NSStringFromClass([value class]) ?: @"?";
}

static NSString *ResponseEnvelopeSummary(NSData *data, NSURLResponse *response, NSError *error) {
    NSInteger httpStatus = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
    if (error) return [NSString stringWithFormat:@"BODY http=%ld transportErr=%ld", (long)httpStatus, (long)error.code];
    if (!data.length) return [NSString stringWithFormat:@"BODY http=%ld empty", (long)httpStatus];

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class]) {
        return [NSString stringWithFormat:@"BODY http=%ld nonJSON bytes=%lu", (long)httpStatus, (unsigned long)data.length];
    }

    NSDictionary *dict = (NSDictionary *)json;
    id code = dict[@"code"] ?: dict[@"status"] ?: dict[@"status_code"];
    id message = dict[@"msg"] ?: dict[@"message"];
    id errorObject = dict[@"error"];
    if (!message && [errorObject isKindOfClass:NSDictionary.class]) {
        message = ((NSDictionary *)errorObject)[@"message"] ?: ((NSDictionary *)errorObject)[@"msg"];
    } else if (!message && [errorObject isKindOfClass:NSString.class]) {
        message = errorObject;
    }
    id payload = dict[@"data"] ?: dict[@"result"];

    return [NSString stringWithFormat:@"BODY http=%ld code=%@ msg=%@ data=%@",
            (long)httpStatus,
            NetScalar(code),
            NetScalar(message),
            NetDataShape(payload)];
}

static IMP OriginalResumeIMPForObject(id object) {
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        NSValue *value = objc_getAssociatedObject((id)cls, kNetOriginalResumeKey);
        if (value) return [value pointerValue];
    }
    return NULL;
}

static IMP OriginalDataTaskIMPForObject(id object) {
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        NSValue *value = objc_getAssociatedObject((id)cls, kNetOriginalDataTaskKey);
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

static NSURLSessionDataTask *NetDataTaskWithRequestCompletion(id self, SEL _cmd, NSURLRequest *request, NetDataCompletion completion) {
    IMP original = OriginalDataTaskIMPForObject(self);
    if (!original || original == (IMP)NetDataTaskWithRequestCompletion) return nil;

    if (!request || !IsInterestingRequest(request)) {
        return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *, NetDataCompletion))original)(self, _cmd, request, completion);
    }

    NSString *brief = RequestBrief(request);
    NetDataCompletion wrapped = ^(NSData *data, NSURLResponse *response, NSError *error) {
        NetPublish(ResponseEnvelopeSummary(data, response, error));
        if (completion) completion(data, response, error);
    };
    return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *, NetDataCompletion))original)(self, _cmd, request, wrapped);
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

static void HookDataTaskMethods(void) {
    SEL selector = NSSelectorFromString(@"dataTaskWithRequest:completionHandler:");
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    count = objc_getClassList(classes, count);

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (cls != NSURLSession.class && ![cls isSubclassOfClass:NSURLSession.class]) continue;
        Method method = NULL;
        if (!ClassDefinesSelector(cls, selector, &method) || !method) continue;
        if (objc_getAssociatedObject((id)cls, kNetOriginalDataTaskKey)) continue;
        IMP original = method_getImplementation(method);
        if (!original || original == (IMP)NetDataTaskWithRequestCompletion) continue;
        objc_setAssociatedObject((id)cls, kNetOriginalDataTaskKey, [NSValue valueWithPointer:original], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        method_setImplementation(method, (IMP)NetDataTaskWithRequestCompletion);
    }
    free(classes);
}

static void InstallNetworkDiagnostics(void) {
    HookResumeMethods();
    HookDataTaskMethods();
}

__attribute__((constructor)) static void NetworkDiagnosticsInit(void) {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.50 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            InstallNetworkDiagnostics();
            NetPublish(@"observer active (HTTP + app envelope)");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                InstallNetworkDiagnostics();
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (gObservedRequests == 0) NetPublish(@"NO HTTP(S) request observed after startup");
            });
        });
    }
}
