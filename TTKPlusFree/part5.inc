static BOOL hkFalse0(id self, SEL _cmd) { (void)self;(void)_cmd; return NO; }
static BOOL hkFalse1(id self, SEL _cmd, id arg) { (void)self;(void)_cmd;(void)arg; return NO; }
static void hkNoop0(id self, SEL _cmd) { (void)self;(void)_cmd; }

static void hkViewDidAppear(id self, SEL _cmd, BOOL animated) {
    IMP o=TTKOriginal(self,_cmd); if(o) ((void(*)(id,SEL,BOOL))o)(self,_cmd,animated);
    if (![self isKindOfClass:UIViewController.class]) return; UIViewController *vc=self;
    TTKApplyTabHiding(vc); TTKInstallProfileGestures(vc); TTKInstallDownloadButton(vc); TTKHideWarningsAndRecommendations(vc);
    TTKApplyProfileLabels(vc); TTKApplyCountryPill(vc); TTKApplyGridDates(vc); TTKInstallSettingsGesture(vc);
    TTKInstallStoryEye(vc); TTKInstallMessageEye(vc); TTKInstallLiveButton(vc);
}
static void hkUpdateBottomBar(id self, SEL _cmd) { IMP o=TTKOriginal(self,_cmd); if(o)((void(*)(id,SEL))o)(self,_cmd); if([self isKindOfClass:UIViewController.class])TTKApplyTabHiding(self); }

static void TTKConfirmAndCall(id self, SEL _cmd, id arg, BOOL hasArg, NSString *title, NSString *key) {
    IMP o=TTKOriginal(self,_cmd); if(!o)return; if(!TTKOn(key)){ if(hasArg)((void(*)(id,SEL,id))o)(self,_cmd,arg); else ((void(*)(id,SEL))o)(self,_cmd); return; }
    UIViewController *vc=[self isKindOfClass:UIViewController.class]?self:nil; if(!vc) vc=TTKSafeValue(self,@"viewController"); if(![vc isKindOfClass:UIViewController.class]){ if(hasArg)((void(*)(id,SEL,id))o)(self,_cmd,arg); else((void(*)(id,SEL))o)(self,_cmd); return; }
    UIAlertController*a=[UIAlertController alertControllerWithTitle:title message:@"Are you sure?" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Yes" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction*x){ if(hasArg)((void(*)(id,SEL,id))o)(self,_cmd,arg); else((void(*)(id,SEL))o)(self,_cmd); }]]; [vc presentViewController:a animated:YES completion:nil];
}
static void hkFollow1(id self,SEL _cmd,id arg){ TTKConfirmAndCall(self,_cmd,arg,YES,@"Follow account?",@"TTKPlus_FollowConfirmation"); }
static void hkLike0(id self,SEL _cmd){ NSString*k=[NSStringFromClass([self class]).lowercaseString containsString:@"comment"]?@"TTKPlus_LikeCommentConfirmation":@"TTKPlus_LikeConfirmation"; TTKConfirmAndCall(self,_cmd,nil,NO,@"Like?",k); }
static void hkLike1(id self,SEL _cmd,id arg){ NSString*k=[NSStringFromClass([self class]).lowercaseString containsString:@"comment"]?@"TTKPlus_LikeCommentConfirmation":@"TTKPlus_LikeConfirmation"; TTKConfirmAndCall(self,_cmd,arg,YES,@"Like?",k); }

static void hkLoop1(id self,SEL _cmd,id arg){ if(TTKOn(@"TTKPlus_LoopMode"))return;IMP o=TTKOriginal(self,_cmd);if(o)((void(*)(id,SEL,id))o)(self,_cmd,arg); }

static void TTKInstallHooks(void) {
    int n=objc_getClassList(NULL,0); if(n<=0)return; Class __unsafe_unretained *classes=(Class __unsafe_unretained *)calloc((size_t)n,sizeof(Class)); n=objc_getClassList(classes,n);
    SEL sHasAd=sel_registerName("hasAd"), sAds=sel_registerName("isAds"), sSoft=sel_registerName("isSoftAds"), sProfile=sel_registerName("p_shouldReportProfileView"), sProfileUser=sel_registerName("p_shouldReportHasVeiwedProfileForUser:"), sReport=sel_registerName("reportProfileView"), sBig=sel_registerName("isUserRecommendBigCard"), sShowMask=sel_registerName("showMask");
    SEL sView=sel_registerName("viewDidAppear:"), sBottom=sel_registerName("updateBottomBar"), sFollow=sel_registerName("onFollowViewClicked:"), sLike0=sel_registerName("onLikeButtonClicked"), sLike1=sel_registerName("onLikeAction:"), sLoop=sel_registerName("playerWillLoopPlay:");
    for(int i=0;i<n;i++) { Class c=classes[i]; if(!TTKInterestingClass(c))continue;
        if(TTKOn(@"TTKPlus_AdBlock")){ TTKHookDirect(c,sHasAd,(IMP)hkFalse0); TTKHookDirect(c,sAds,(IMP)hkFalse0); TTKHookDirect(c,sSoft,(IMP)hkFalse0); }
        if(TTKOn(@"TTKPlus_AnonymousProfileView")){ TTKHookDirect(c,sProfile,(IMP)hkFalse0); TTKHookDirect(c,sProfileUser,(IMP)hkFalse1); TTKHookDirect(c,sReport,(IMP)hkNoop0); }
        if(TTKOn(@"TTKPlus_SkipRecommendations")) TTKHookDirect(c,sBig,(IMP)hkFalse0);
        if(TTKOn(@"TTKPlus_DisableWarnings")) TTKHookDirect(c,sShowMask,(IMP)hkNoop0);
        TTKHookDirect(c,sView,(IMP)hkViewDidAppear); TTKHookDirect(c,sBottom,(IMP)hkUpdateBottomBar);
        TTKHookDirect(c,sFollow,(IMP)hkFollow1); TTKHookDirect(c,sLike0,(IMP)hkLike0); TTKHookDirect(c,sLike1,(IMP)hkLike1); TTKHookDirect(c,sLoop,(IMP)hkLoop1);
    }
    free(classes);
    TTKHookNamed(@"AWENewFeedTableViewController",sView,(IMP)hkViewDidAppear);
    TTKHookNamed(@"AWEFeedCellViewController",sView,(IMP)hkViewDidAppear);
    TTKHookNamed(@"AWEAwemeDetailCellViewController",sView,(IMP)hkViewDidAppear);
    TTKHookNamed(@"CTCarrier",sel_registerName("isoCountryCode"),(IMP)hkRegionISO);
    TTKHookNamed(@"CTCarrier",sel_registerName("mobileCountryCode"),(IMP)hkRegionMCC);
    TTKHookNamed(@"CTCarrier",sel_registerName("mobileNetworkCode"),(IMP)hkRegionMNC);
    for(NSString*cn in @[@"TIKTOKRegionManager",@"TTKStoreRegionService",@"TTKStoreRegionModel",@"TTKPassportAppStoreRegionModel",@"ATSRegionCacheManager"]) {
        for(NSString*sn in @[@"region",@"systemRegion",@"localRegion",@"storeRegion",@"currentRegionV2",@"currentAppRegion"]) TTKHookNamed(cn,sel_registerName(sn.UTF8String),(IMP)hkRegionGeneric);
    }
}

__attribute__((constructor)) static void TTKPlusFreeInit(void) {
    gOriginals=[NSMutableDictionary dictionary]; gInstalled=[NSMutableSet set]; TTKRegisterDefaults();
    dispatch_async(dispatch_get_main_queue(), ^{ TTKInstallHooks();
        for(NSTimeInterval t=1;t<=12;t+=2) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(t*NSEC_PER_SEC)),dispatch_get_main_queue(),^{TTKInstallHooks();});
        NSLog(@"[%@] loaded — clean replacement runtime active",kTTKTag);
    });
}
