@interface TTKActionProxy : NSObject
@property(nonatomic,weak) UIViewController *host;
@property(nonatomic,weak) UIView *boundView;
@end
@implementation TTKActionProxy
- (void)downloadTapped:(UIButton *)sender {
    UIViewController *vc = self.host; id model = TTKFindModel(vc); NSURL *u = TTKURLFromValue(model,0);
    if (!u) { TTKToast(vc,@"TTKPlus: video URL not found"); return; }
    TTKToast(vc,@"TTKPlus: downloading…");
    [[[NSURLSession sharedSession] downloadTaskWithURL:u completionHandler:^(NSURL *loc, NSURLResponse *r, NSError *e) {
        if (!loc || e) { dispatch_async(dispatch_get_main_queue(), ^{ TTKToast(vc,@"TTKPlus: download failed"); }); return; }
        NSString *dst = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ttk-%@.mp4",NSUUID.UUID.UUIDString]];
        [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
        if (![[NSFileManager defaultManager] copyItemAtURL:loc toURL:[NSURL fileURLWithPath:dst] error:nil]) return;
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{ [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:dst]]; }
          completionHandler:^(BOOL ok, NSError *err){ dispatch_async(dispatch_get_main_queue(), ^{ TTKToast(vc, ok?@"TTKPlus: saved to Photos":@"TTKPlus: save failed"); }); }];
    }] resume];
}
- (void)downloadLongPressed:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan || !TTKOn(@"TTKPlus_ClearDisplayEnabled")) return;
    UIViewController *vc=self.host; UIView *root=vc.view; BOOL anyVisible=NO;
    for (UIView *v in root.subviews) if (v.tag != kTTKDownloadTag && !v.hidden) { anyVisible=YES; break; }
    for (UIView *v in root.subviews) if (v.tag != kTTKDownloadTag) v.hidden=anyVisible;
    TTKToast(vc, anyVisible?@"TTKPlus: display cleared":@"TTKPlus: display restored");
}
- (void)avatarLong:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIImageView *iv=(UIImageView *)g.view; if (![iv isKindOfClass:UIImageView.class] || !iv.image) return;
    UIViewController *vc=self.host; UIViewController *p=[UIViewController new]; p.view.backgroundColor=UIColor.blackColor;
    UIImageView *full=[[UIImageView alloc]initWithImage:iv.image]; full.contentMode=UIViewContentModeScaleAspectFit; full.frame=p.view.bounds; full.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; [p.view addSubview:full];
    UIButton *save=[UIButton buttonWithType:UIButtonTypeSystem]; [save setTitle:@"Save" forState:UIControlStateNormal]; save.frame=CGRectMake(20,50,80,44);
    [save addAction:[UIAction actionWithHandler:^(__unused UIAction *a){ UIImageWriteToSavedPhotosAlbum(iv.image,nil,nil,nil); TTKToast(p,@"Saved"); }] forControlEvents:UIControlEventTouchUpInside]; [p.view addSubview:save];
    [vc presentViewController:p animated:YES completion:nil];
}
- (void)bioLong:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return; UILabel *l=(UILabel *)g.view;
    if (![l isKindOfClass:UILabel.class] || !l.text.length) return; UIPasteboard.generalPasteboard.string=l.text; TTKToast(self.host,@"TTKPlus: bio copied");
}
@end

static char kProxyKey;
static TTKActionProxy *TTKProxy(UIViewController *vc) {
    TTKActionProxy *p=objc_getAssociatedObject(vc,&kProxyKey); if (!p) { p=[TTKActionProxy new]; p.host=vc; objc_setAssociatedObject(vc,&kProxyKey,p,OBJC_ASSOCIATION_RETAIN_NONATOMIC);} return p;
}

static void TTKWalkViews(UIView *v, void (^block)(UIView *)) {
    if (!v) return; block(v); for (UIView *s in v.subviews) TTKWalkViews(s,block);
}

static NSString *TTKViewTokens(UIView *v) {
    NSMutableString *s=[NSMutableString stringWithString:NSStringFromClass(v.class).lowercaseString ?: @""];
    if (v.accessibilityIdentifier.length) [s appendFormat:@" %@",v.accessibilityIdentifier.lowercaseString];
    if (v.accessibilityLabel.length) [s appendFormat:@" %@",v.accessibilityLabel.lowercaseString];
    if ([v isKindOfClass:UIButton.class]) { NSString *t=[(UIButton*)v titleForState:UIControlStateNormal]; if(t.length)[s appendFormat:@" %@",t.lowercaseString]; }
    if ([v isKindOfClass:UILabel.class]) { NSString *t=((UILabel*)v).text; if(t.length)[s appendFormat:@" %@",t.lowercaseString]; }
    return s;
}

static void TTKApplyTabHiding(UIViewController *vc) {
    BOOL f=TTKOn(@"TTKPlus_HideFriendsTab"), c=TTKOn(@"TTKPlus_HideCreateTab"), i=TTKOn(@"TTKPlus_HideInboxTab");
    if (!f&&!c&&!i) return;
    CGFloat cutoff = vc.view.bounds.size.height * .68;
    TTKWalkViews(vc.view, ^(UIView *v){ if (CGRectGetMinY([v convertRect:v.bounds toView:vc.view]) < cutoff) return; NSString *t=TTKViewTokens(v);
        if ((f && ([t containsString:@"friend"]||[t containsString:@"friends"])) ||
            (i && ([t containsString:@"inbox"]||[t containsString:@"message"]||[t containsString:@"notification"])) ||
            (c && ([t containsString:@"create"]||[t containsString:@"publish"]||[t containsString:@"plusbutton"]))) v.hidden=YES; });
}

static void TTKInstallProfileGestures(UIViewController *vc) {
    NSString *cn=NSStringFromClass(vc.class).lowercaseString; if (![cn containsString:@"profile"]) return;
    __block UIImageView *bestImage=nil; __block CGFloat bestArea=0; __block UILabel *bestLabel=nil; __block CGFloat bestLabelArea=0;
    TTKWalkViews(vc.view, ^(UIView *v){
        if (TTKOn(@"TTKPlus_AvatarLongPress") && [v isKindOfClass:UIImageView.class]) { CGFloat a=v.bounds.size.width*v.bounds.size.height; if(a>bestArea && a>2500 && a<50000){bestArea=a;bestImage=(UIImageView*)v;} }
        if (TTKOn(@"TTKPlus_Bio") && [v isKindOfClass:UILabel.class]) { UILabel*l=(UILabel*)v; CGFloat a=v.bounds.size.width*v.bounds.size.height; if(l.text.length>8 && a>bestLabelArea){bestLabelArea=a;bestLabel=l;} }
    });
    TTKActionProxy*p=TTKProxy(vc);
    if(bestImage && !objc_getAssociatedObject(bestImage,&kProxyKey)){ bestImage.userInteractionEnabled=YES; UILongPressGestureRecognizer*g=[[UILongPressGestureRecognizer alloc]initWithTarget:p action:@selector(avatarLong:)]; [bestImage addGestureRecognizer:g]; objc_setAssociatedObject(bestImage,&kProxyKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    if(bestLabel && !objc_getAssociatedObject(bestLabel,&kProxyKey)){ bestLabel.userInteractionEnabled=YES; UILongPressGestureRecognizer*g=[[UILongPressGestureRecognizer alloc]initWithTarget:p action:@selector(bioLong:)]; [bestLabel addGestureRecognizer:g]; objc_setAssociatedObject(bestLabel,&kProxyKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
}

static void TTKInstallDownloadButton(UIViewController *vc) {
    if (!TTKOn(@"TTKPlus_DownloadButton") || [vc.view viewWithTag:kTTKDownloadTag]) return;
    NSString *cn=NSStringFromClass(vc.class); if (![cn containsString:@"Feed"] && ![cn containsString:@"Aweme"] && ![cn containsString:@"DetailCell"]) return;
    UIButton*b=[UIButton buttonWithType:UIButtonTypeSystem]; b.tag=kTTKDownloadTag; [b setTitle:@"↓" forState:UIControlStateNormal]; b.titleLabel.font=[UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    b.tintColor=UIColor.whiteColor; b.backgroundColor=[UIColor colorWithWhite:0 alpha:.42]; b.layer.cornerRadius=24; b.translatesAutoresizingMaskIntoConstraints=NO;
    TTKActionProxy*p=TTKProxy(vc); [b addTarget:p action:@selector(downloadTapped:) forControlEvents:UIControlEventTouchUpInside]; UILongPressGestureRecognizer*g=[[UILongPressGestureRecognizer alloc]initWithTarget:p action:@selector(downloadLongPressed:)]; [b addGestureRecognizer:g];
    [vc.view addSubview:b]; [NSLayoutConstraint activateConstraints:@[[b.trailingAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.trailingAnchor constant:-12],[b.centerYAnchor constraintEqualToAnchor:vc.view.centerYAnchor constant:110],[b.widthAnchor constraintEqualToConstant:48],[b.heightAnchor constraintEqualToConstant:48]]];
}

static void TTKHideWarningsAndRecommendations(UIViewController *vc) {
    BOOL warn=TTKOn(@"TTKPlus_DisableWarnings"), rec=TTKOn(@"TTKPlus_SkipRecommendations"); if(!warn&&!rec)return;
    TTKWalkViews(vc.view, ^(UIView*v){ NSString*t=TTKViewTokens(v);
        if(warn && ([t containsString:@"sensitive"]||[t containsString:@"warning"]||[t containsString:@"contentmask"])) v.hidden=YES;
        if(rec && ([t containsString:@"recommend"]||[t containsString:@"suggested"]||[t containsString:@"bigcard"])) v.hidden=YES;
    });
}

