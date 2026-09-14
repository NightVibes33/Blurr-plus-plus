@interface TTKParityProxy : NSObject
@property(nonatomic,weak) UIViewController *host;
- (void)openSettings:(id)sender;
- (void)storySeen:(id)sender;
- (void)messageRead:(id)sender;
- (void)liveToggle:(id)sender;
@end

@interface TTKSettingsVC : UITableViewController
@property(nonatomic,strong) NSArray<NSArray<NSDictionary *> *> *sections;
@end

static TTKParityProxy *TTKParity(UIViewController *vc){ TTKParityProxy*p=objc_getAssociatedObject(vc,&kParityProxyKey); if(!p){p=[TTKParityProxy new];p.host=vc;objc_setAssociatedObject(vc,&kParityProxyKey,p,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}return p; }

static void TTKAddFeatureButton(UIViewController *vc, NSInteger tag, NSString *title, SEL action, CGRect frame) {
    if([vc.view viewWithTag:tag])return; UIButton*b=[UIButton buttonWithType:UIButtonTypeSystem]; b.tag=tag;b.frame=frame;b.autoresizingMask=UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleBottomMargin;
    [b setTitle:title forState:UIControlStateNormal];b.titleLabel.font=[UIFont systemFontOfSize:17 weight:UIFontWeightBold];b.tintColor=UIColor.whiteColor;b.backgroundColor=[UIColor colorWithWhite:0 alpha:.48];b.layer.cornerRadius=22;
    [b addTarget:TTKParity(vc) action:action forControlEvents:UIControlEventTouchUpInside];[vc.view addSubview:b];
}

static void TTKInstallSettingsGesture(UIViewController *vc) {
    NSString *cn=NSStringFromClass(vc.class).lowercaseString;if(![cn containsString:@"profile"])return;
    static char key; if(objc_getAssociatedObject(vc.view,&key))return;
    UILongPressGestureRecognizer*g=[[UILongPressGestureRecognizer alloc]initWithTarget:TTKParity(vc) action:@selector(openSettings:)];g.minimumPressDuration=1.15;g.cancelsTouchesInView=NO;[vc.view addGestureRecognizer:g];objc_setAssociatedObject(vc.view,&key,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void TTKInstallStoryEye(UIViewController *vc) {
    if(!TTKOn(@"TTKPlus_StoryEye"))return;NSString*cn=NSStringFromClass(vc.class).lowercaseString;if(![cn containsString:@"story"])return;
    TTKAddFeatureButton(vc,0x54545345,@"👁",@selector(storySeen:),CGRectMake(vc.view.bounds.size.width-62,vc.view.safeAreaInsets.top+52,44,44));
}
static void TTKInstallMessageEye(UIViewController *vc) {
    if(!TTKOn(@"TTKPlus_MsgEye"))return;NSString*cn=NSStringFromClass(vc.class).lowercaseString;if(!([cn containsString:@"message"]||[cn containsString:@"chat"]||[cn containsString:@"conversation"]))return;
    TTKAddFeatureButton(vc,0x54544D45,@"👁",@selector(messageRead:),CGRectMake(vc.view.bounds.size.width-62,vc.view.safeAreaInsets.top+52,44,44));
}
static void TTKInstallLiveButton(UIViewController *vc) {
    if(!TTKOn(@"TTKPlus_LiveAutoClick"))return;NSString*cn=NSStringFromClass(vc.class).lowercaseString;if(![cn containsString:@"live"])return;
    TTKAddFeatureButton(vc,0x54544C41,@"♥",@selector(liveToggle:),CGRectMake(vc.view.bounds.size.width-62,vc.view.safeAreaInsets.top+104,44,44));
}

static UIControl *TTKFindLikeControl(UIView *root) {
    __block UIControl *hit=nil; TTKWalkViews(root,^(UIView*v){if(hit||![v isKindOfClass:UIControl.class])return;NSString*t=TTKViewTokens(v);if([t containsString:@"like"]||[t containsString:@"heart"]||[t containsString:@"digg"])hit=(UIControl*)v;});return hit;
}

@implementation TTKParityProxy
- (void)openSettings:(id)sender { if([sender isKindOfClass:UILongPressGestureRecognizer.class] && [(UILongPressGestureRecognizer*)sender state]!=UIGestureRecognizerStateBegan)return; TTKSettingsVC*s=[TTKSettingsVC new];UINavigationController*n=[[UINavigationController alloc]initWithRootViewController:s];[self.host presentViewController:n animated:YES completion:nil]; }
- (void)storySeen:(id)sender { (void)sender; UIViewController*vc=self.host; id model=TTKFindModel(vc); id responder=TTKFindResponder(vc,sel_registerName("markStoryReaded:")); if(responder){((void(*)(id,SEL,id))objc_msgSend)(responder,sel_registerName("markStoryReaded:"),model);} TTKSetSafe(model,@"viewed",@YES);TTKSetSafe(model,@"hasViewed",@YES);TTKToast(vc,@"TTKPlus: marked story seen"); }
- (void)messageRead:(id)sender { (void)sender;UIViewController*vc=self.host;id conv=TTKFirstValue(vc,@[@"conversation",@"currentConversation",@"conversationInfo",@"model"]);SEL s=sel_registerName("clientMarkConversationAsRead:sendToServer:");id responder=TTKFindResponder(vc,s);if(responder&&conv)((void(*)(id,SEL,id,BOOL))objc_msgSend)(responder,s,conv,YES);TTKSetSafe(conv,@"unreadCount",@0);TTKToast(vc,@"TTKPlus: marked read"); }
- (void)liveToggle:(id)sender { (void)sender;UIViewController*vc=self.host;NSTimer*t=objc_getAssociatedObject(vc,&kLiveTimerKey);if(t){[t invalidate];objc_setAssociatedObject(vc,&kLiveTimerKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);TTKToast(vc,@"TTKPlus: auto-like stopped");return;} NSInteger max=[[NSUserDefaults standardUserDefaults] integerForKey:@"TTKPlus_LiveAutoClickCount"];if(max==0)max=100;__block NSInteger sent=0; __weak UIViewController*wvc=vc; t=[NSTimer scheduledTimerWithTimeInterval:.11 repeats:YES block:^(NSTimer*timer){UIViewController*sv=wvc;if(!sv){[timer invalidate];return;}if(max>0&&sent>=max){[timer invalidate];objc_setAssociatedObject(sv,&kLiveTimerKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);TTKToast(sv,@"TTKPlus: auto-like complete");return;}UIControl*c=TTKFindLikeControl(sv.view);if(c)[c sendActionsForControlEvents:UIControlEventTouchUpInside];else{SEL s=sel_registerName("onLikeButtonClicked");id r=TTKFindResponder(sv,s);if(r)((void(*)(id,SEL))objc_msgSend)(r,s);}sent++;}];objc_setAssociatedObject(vc,&kLiveTimerKey,t,OBJC_ASSOCIATION_RETAIN_NONATOMIC);TTKToast(vc,max<0?@"TTKPlus: auto-like unlimited":@"TTKPlus: auto-like started"); }
@end
