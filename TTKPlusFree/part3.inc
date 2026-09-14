#pragma mark - Parity helpers

static UIViewController *TTKVCForView(UIView *view) {
    UIResponder *r=view;
    while ((r=r.nextResponder)) if ([r isKindOfClass:UIViewController.class]) return (UIViewController *)r;
    return nil;
}

static id TTKFirstValue(id obj, NSArray<NSString *> *keys) {
    for (NSString *k in keys) { id v=TTKSafeValue(obj,k); if(v && v != NSNull.null) return v; }
    return nil;
}

static NSString *TTKStringValue(id v) {
    if ([v isKindOfClass:NSString.class] && [v length]) return v;
    if ([v respondsToSelector:@selector(stringValue)]) return [v stringValue];
    return nil;
}

static NSInteger TTKIntegerValue(id v) {
    if ([v respondsToSelector:@selector(integerValue)]) return [v integerValue];
    return 0;
}

static id TTKFindUser(id root) {
    if (!root) return nil;
    id u=TTKFirstValue(root,@[@"user",@"author",@"userModel",@"profileUser",@"currentUser",@"displayUser"]);
    if (u) return u;
    id m=TTKFindModel([root isKindOfClass:UIViewController.class] ? root : nil);
    return TTKFirstValue(m,@[@"author",@"user",@"userModel"]);
}

static id TTKFindResponder(id root, SEL sel) {
    if (!root || !sel) return nil;
    if ([root respondsToSelector:sel]) return root;
    NSArray *keys=@[@"viewModel",@"model",@"manager",@"service",@"operator",@"messageManager",@"storyManager",@"interactionController",@"dataSource",@"delegate",@"container"];
    for (NSString *k in keys) { id x=TTKSafeValue(root,k); if([x respondsToSelector:sel]) return x; }
    return nil;
}

static NSString *TTKRelativeAge(id value) {
    NSTimeInterval t=0;
    if ([value respondsToSelector:@selector(doubleValue)]) t=[value doubleValue];
    if (t > 100000000000.0) t/=1000.0;
    if (t <= 0) return @"";
    NSTimeInterval d=MAX(0,[NSDate.date timeIntervalSince1970]-t);
    if (d<60) return @"now";
    if (d<3600) return [NSString stringWithFormat:@"%ldm",(long)(d/60)];
    if (d<86400) return [NSString stringWithFormat:@"%ldh",(long)(d/3600)];
    if (d<86400*30) return [NSString stringWithFormat:@"%ldd",(long)(d/86400)];
    if (d<86400*365) return [NSString stringWithFormat:@"%ldmo",(long)(d/(86400*30))];
    return [NSString stringWithFormat:@"%ldy",(long)(d/(86400*365))];
}

static UILabel *TTKOverlayLabel(UIView *host, NSInteger tag, CGRect frame) {
    UILabel *l=(UILabel *)[host viewWithTag:tag];
    if (![l isKindOfClass:UILabel.class]) {
        l=[[UILabel alloc]initWithFrame:frame]; l.tag=tag; l.textColor=UIColor.whiteColor;
        l.backgroundColor=[UIColor colorWithWhite:0 alpha:.56]; l.layer.cornerRadius=8; l.clipsToBounds=YES;
        l.font=[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold]; l.textAlignment=NSTextAlignmentCenter;
        l.numberOfLines=2; l.autoresizingMask=UIViewAutoresizingFlexibleRightMargin|UIViewAutoresizingFlexibleBottomMargin;
        [host addSubview:l];
    }
    l.frame=frame; l.hidden=NO; return l;
}

static void TTKApplyProfileLabels(UIViewController *vc) {
    NSString *cn=NSStringFromClass(vc.class).lowercaseString;
    if (![cn containsString:@"profile"]) return;
    id user=TTKFindUser(vc);
    if (TTKOn(@"TTKPlus_ShowFollowBadge")) {
        BOOL following=[TTKFirstValue(user,@[@"isFollowing",@"following",@"followStatus"]) boolValue];
        BOOL follower=[TTKFirstValue(user,@[@"isFollower",@"follower",@"followerStatus"]) boolValue];
        NSString *status=following&&follower?@"🤝 Mutual":(follower?@"👁 Follows you":(following?@"👻 You follow":@"👻 Not mutual"));
        UILabel *l=TTKOverlayLabel(vc.view,0x54544642,CGRectMake(12,vc.view.safeAreaInsets.top+8,112,28)); l.text=status;
    }
    if (TTKOn(@"TTKPlus_ShowVideoCount")) {
        id count=TTKFirstValue(user,@[@"videosCount",@"awemeCount",@"videoCount",@"aweme_count"]);
        if (!count) count=TTKFirstValue(vc,@[@"videosCount",@"awemeCount",@"videoCount"]);
        if (count) { UILabel*l=TTKOverlayLabel(vc.view,0x54545643,CGRectMake(132,vc.view.safeAreaInsets.top+8,92,28)); l.text=[NSString stringWithFormat:@"%@ posts",count]; }
    }
}

static NSString *TTKCountryEmoji(NSString *code) {
    if (code.length!=2) return @"🌐";
    NSString *u=code.uppercaseString; unichar c1=[u characterAtIndex:0], c2=[u characterAtIndex:1];
    if(c1<'A'||c1>'Z'||c2<'A'||c2>'Z')return @"🌐";
    UTF32Char scalars[2]={0x1F1E6+(c1-'A'),0x1F1E6+(c2-'A')};
    return [[NSString alloc] initWithBytes:scalars length:sizeof(scalars) encoding:NSUTF32LittleEndianStringEncoding] ?: @"🌐";
}

static void TTKApplyCountryPill(UIViewController *vc) {
    if(!TTKOn(@"TTKPlus_CountryPill"))return;
    NSString *cn=NSStringFromClass(vc.class).lowercaseString;
    if(![cn containsString:@"feed"] && ![cn containsString:@"aweme"] && ![cn containsString:@"detailcell"])return;
    id model=TTKFindModel(vc); id user=TTKFirstValue(model,@[@"author",@"user",@"userModel"]);
    NSString *country=TTKStringValue(TTKFirstValue(user,@[@"isoCountryCode",@"region",@"countryCode",@"country"]));
    if(!country.length)country=TTKStringValue(TTKFirstValue(model,@[@"region",@"countryCode",@"isoCountryCode"]));
    NSString *age=TTKRelativeAge(TTKFirstValue(model,@[@"createTime",@"create_time",@"timestamp",@"publishTime"]));
    if(!country.length && !age.length)return;
    UILabel*l=TTKOverlayLabel(vc.view,0x54544350,CGRectMake(12,vc.view.safeAreaInsets.top+44,128,28));
    l.text=[NSString stringWithFormat:@"%@ %@%@",TTKCountryEmoji(country ?: @""),country.uppercaseString ?: @"",age.length?[NSString stringWithFormat:@" • %@",age]:@""];
}

static void TTKApplyGridDates(UIViewController *vc) {
    if(!TTKOn(@"TTKPlus_GridDate"))return;
    NSString *cn=NSStringFromClass(vc.class).lowercaseString; if(![cn containsString:@"profile"]&&! [cn containsString:@"grid"])return;
    TTKWalkViews(vc.view,^(UIView*v){ if(![v isKindOfClass:UICollectionViewCell.class])return; id model=TTKFirstValue(v,@[@"aweme",@"model",@"item",@"awemeModel"]); NSString *age=TTKRelativeAge(TTKFirstValue(model,@[@"createTime",@"create_time",@"timestamp",@"publishTime"])); if(!age.length)return;
        UILabel*l=TTKOverlayLabel(v,0x54544744,CGRectMake(4,MAX(2,v.bounds.size.height-22),48,18)); l.font=[UIFont systemFontOfSize:9 weight:UIFontWeightBold]; l.text=age; });
}

static void TTKSetSafe(id obj, NSString *key, id value) { @try { [obj setValue:value forKey:key]; } @catch(__unused NSException *e){} }

static char kParityProxyKey, kLiveTimerKey, kLiveCountKey;
