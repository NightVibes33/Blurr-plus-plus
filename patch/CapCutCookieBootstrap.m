#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString *const kSeedCookieName = @"CapCutSeedCookies.binarycookies";

static void InstallSeedCookie(void) {
    @autoreleasepool {
        NSString *source = [[NSBundle mainBundle] pathForResource:@"CapCutSeedCookies" ofType:@"binarycookies"];
        if (source.length == 0) return;

        NSString *cookiesDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Cookies"];
        NSString *target = [cookiesDir stringByAppendingPathComponent:@"Cookies.binarycookies"];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *error = nil;

        [fm createDirectoryAtPath:cookiesDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&error];
        if (error) return;

        NSString *temp = [target stringByAppendingString:@".seedtmp"];
        [fm removeItemAtPath:temp error:nil];
        if (![fm copyItemAtPath:source toPath:temp error:&error]) return;

        [fm removeItemAtPath:target error:nil];
        [fm moveItemAtPath:temp toPath:target error:nil];
    }
}

__attribute__((constructor))
static void CapCutCookieBootstrap(void) {
    InstallSeedCookie();
    dispatch_async(dispatch_get_main_queue(), ^{
        InstallSeedCookie();
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            InstallSeedCookie();
        }];
    });
}
