// Coffee Buzz ARM — Objective-C / AppKit, no storyboards, lazily-built windows (minimal memory)
#import <Cocoa/Cocoa.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>

enum { ModeOff = 0, ModeBuzz = 1, ModeDoze = 2 };

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }

@interface App : NSObject <NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate>
@property NSStatusItem *item;
@property NSMenu *menu;
@property NSMenuItem *mBuzz, *mDoze, *mOff, *mStatus, *mTimerRoot, *mPause, *mStop, *mWindow;
@property NSInteger mode;
@property IOPMAssertionID aSys, aDisp;
@property NSDate *timerEnd;
@property NSTimeInterval paused;           // >0 when timer paused
@property NSTimer *fire, *ticker, *shutoffTimer;
@property CFRunLoopSourceRef psSource;
@property BOOL lowBatteryFired, shutoffFired;
@property NSWindow *prefs, *panel;
@property NSStackView *rulesStack;
@property NSSegmentedControl *seg;
@property NSTextField *panelLabel;
@property NSMutableArray<NSMutableDictionary *> *rules;
@end

@implementation App

#pragma mark - Names / icons
- (NSString *)nameFor:(NSInteger)m {
    BOOL s = [D() boolForKey:@"simple"];
    if (m == ModeBuzz) return s ? @"Keep Awake" : @"Buzz Mode";
    if (m == ModeDoze) return s ? @"Allow Display Sleep" : @"Doze Mode";
    return @"Off";
}
- (NSImage *)iconFor:(NSInteger)m {
    NSString *n = m == ModeBuzz ? @"cup.and.saucer.fill" : m == ModeDoze ? @"capsule.fill" : @"zzz";
    NSImage *i = [NSImage imageWithSystemSymbolName:n accessibilityDescription:[self nameFor:m]];
    i.template = YES; return i;
}
- (NSString *)fmt:(NSTimeInterval)s {
    long t = (long)ceil(MAX(0, s));
    return [NSString stringWithFormat:@"%ld:%02ld:%02ld", t / 3600, t % 3600 / 60, t % 60];
}
- (NSTimeInterval)remaining {
    if (self.paused > 0) return self.paused;
    return self.timerEnd ? [self.timerEnd timeIntervalSinceNow] : 0;
}

#pragma mark - Launch
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    [D() registerDefaults:@{@"control": @0, @"rightClick": @YES, @"notifyMode": @YES, @"notifyTimer": @YES,
        @"notifyRules": @YES,
        @"rules": @[@{@"type": @"battery", @"enabled": @NO, @"action": @0, @"hours": @3},
                    @{@"type": @"shutoff", @"enabled": @YES, @"action": @0, @"hours": @3}]}];
    self.rules = [NSMutableArray array];
    for (NSDictionary *r in [D() arrayForKey:@"rules"]) [self.rules addObject:[r mutableCopy]];
    [self buildMenu];
    [self applyControlMode];
    self.psSource = IOPSNotificationCreateRunLoopSource(powerChanged, (__bridge void *)self);
    if (self.psSource) CFRunLoopAddSource(CFRunLoopGetMain(), self.psSource, kCFRunLoopCommonModes);
    if ([D() boolForKey:@"notifyStart"]) [self notify:@"Coffee Buzz" body:@"Coffee Buzz is running." key:@"notifyStart"];
    [self updateUI];
}
- (void)applicationWillTerminate:(NSNotification *)n { [self releaseAssertions]; }
- (BOOL)applicationShouldHandleReopen:(NSApplication *)a hasVisibleWindows:(BOOL)f {
    if ([D() integerForKey:@"control"] != 0) [self showPanel];
    return YES;
}

#pragma mark - Menu
- (NSMenuItem *)add:(NSString *)t sel:(SEL)s to:(NSMenu *)m {
    NSMenuItem *i = [m addItemWithTitle:t action:s keyEquivalent:@""]; i.target = self; return i;
}
- (void)buildMenu {
    NSMenu *m = self.menu = [[NSMenu alloc] init]; m.delegate = self; m.autoenablesItems = NO;
    self.mBuzz = [self add:@"" sel:@selector(pickMode:) to:m]; self.mBuzz.tag = ModeBuzz;
    self.mDoze = [self add:@"" sel:@selector(pickMode:) to:m]; self.mDoze.tag = ModeDoze;
    self.mOff  = [self add:@"" sel:@selector(pickMode:) to:m]; self.mOff.tag = ModeOff;
    [m addItem:NSMenuItem.separatorItem];
    self.mStatus = [m addItemWithTitle:@"Not set" action:nil keyEquivalent:@""]; self.mStatus.enabled = NO;
    self.mTimerRoot = [m addItemWithTitle:@"Set Timer" action:nil keyEquivalent:@""];
    NSMenu *sub = [[NSMenu alloc] init];
    for (NSArray *p in @[@[@"15 minutes", @15], @[@"30 minutes", @30], @[@"1 hour", @60], @[@"2 hours", @120],
                         @[@"4 hours", @240], @[@"8 hours", @480]]) {
        NSMenuItem *i = [self add:p[0] sel:@selector(pickTimer:) to:sub]; i.tag = [p[1] integerValue];
    }
    [sub addItem:NSMenuItem.separatorItem];
    [self add:@"Custom…" sel:@selector(customTimer) to:sub];
    self.mTimerRoot.submenu = sub;
    self.mPause = [self add:@"Pause Timer" sel:@selector(togglePause) to:m];
    self.mStop  = [self add:@"Stop Timer" sel:@selector(stopTimer) to:m];
    [m addItem:NSMenuItem.separatorItem];
    self.mWindow = [self add:@"Show Window" sel:@selector(showPanel) to:m];
    [self add:@"About Coffee Buzz" sel:@selector(about) to:m];
    [self add:@"Preferences…" sel:@selector(showPrefs) to:m];
    [m addItem:NSMenuItem.separatorItem];
    [self add:@"Quit Coffee Buzz" sel:@selector(quit) to:m];
}
- (void)menuNeedsUpdate:(NSMenu *)m {
    NSArray *items = @[self.mBuzz, self.mDoze, self.mOff];
    for (NSMenuItem *i in items) {
        i.title = [self nameFor:i.tag]; i.image = [self iconFor:i.tag];
        i.state = i.tag == self.mode ? NSControlStateValueOn : NSControlStateValueOff;
    }
    BOOL has = self.timerEnd != nil;
    self.mStatus.title = has ? [NSString stringWithFormat:@"%@%@", [self fmt:[self remaining]], self.paused > 0 ? @" (paused)" : @" left"] : @"Not set";
    self.mStatus.image = [NSImage imageWithSystemSymbolName:@"timer" accessibilityDescription:nil];
    self.mPause.title = self.paused > 0 ? @"Resume Timer" : @"Pause Timer";
    self.mPause.enabled = has; self.mStop.enabled = has;
    self.mWindow.hidden = [D() integerForKey:@"control"] != 2;
}

#pragma mark - Status item / control mode
- (void)applyControlMode {
    NSInteger c = [D() integerForKey:@"control"];
    if (c == 1) { if (self.item) { [NSStatusBar.systemStatusBar removeStatusItem:self.item]; self.item = nil; } }
    else if (!self.item) {
        self.item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
        self.item.button.target = self; self.item.button.action = @selector(statusClick:);
        [self.item.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
    }
    [NSApp setActivationPolicy:c == 0 ? NSApplicationActivationPolicyAccessory : NSApplicationActivationPolicyRegular];
    if (c != 0) [self showPanel]; else [self.panel orderOut:nil];
    [self updateUI];
}
- (void)statusClick:(id)sender {
    NSEvent *e = NSApp.currentEvent;
    BOOL right = e.type == NSEventTypeRightMouseUp || (e.modifierFlags & NSEventModifierFlagControl);
    if (right && [D() boolForKey:@"rightClick"]) {
        [self setMode:(self.mode + 1) % 3 reason:nil];
    } else {
        self.item.menu = self.menu; [self.item.button performClick:nil]; self.item.menu = nil;
    }
}

#pragma mark - Core: modes & assertions
- (void)releaseAssertions {
    if (self.aSys) { IOPMAssertionRelease(self.aSys); self.aSys = 0; }
    if (self.aDisp) { IOPMAssertionRelease(self.aDisp); self.aDisp = 0; }
}
- (void)setMode:(NSInteger)m reason:(NSString *)why {
    BOOL changed = m != self.mode;
    [self releaseAssertions];
    CFStringRef reason = CFSTR("Coffee Buzz");
    if (m >= ModeBuzz) IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep, kIOPMAssertionLevelOn, reason, &_aSys);
    if (m == ModeBuzz) IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep, kIOPMAssertionLevelOn, reason, &_aDisp);
    self.mode = m;
    if (m == ModeOff) [self clearTimer];
    [self scheduleShutoff];
    [self updateUI];
    if (changed) [self notify:@"Coffee Buzz" body:why ?: [NSString stringWithFormat:@"Mode: %@", [self nameFor:m]] key:why ? @"notifyRules" : @"notifyMode"];
}
- (void)pickMode:(NSMenuItem *)i { [self setMode:i.tag reason:nil]; }

#pragma mark - Timer
- (void)clearTimer {
    [self.fire invalidate]; self.fire = nil; self.timerEnd = nil; self.paused = 0;
}
- (void)startTimer:(NSTimeInterval)secs {
    [self clearTimer];
    if (self.mode == ModeOff) [self setMode:ModeBuzz reason:nil];
    self.timerEnd = [NSDate dateWithTimeIntervalSinceNow:secs];
    [self scheduleFire]; [self updateUI];
}
- (void)scheduleFire {
    [self.fire invalidate];
    self.fire = [NSTimer timerWithTimeInterval:[self remaining] target:self selector:@selector(timerDone) userInfo:nil repeats:NO];
    self.fire.tolerance = 0.5;
    [NSRunLoop.mainRunLoop addTimer:self.fire forMode:NSRunLoopCommonModes];
}
- (void)timerDone {
    self.fire = nil; self.timerEnd = nil;
    [self notify:@"Coffee Buzz" body:@"Timer finished." key:@"notifyTimer"];
    BOOL was = [D() boolForKey:@"notifyMode"]; (void)was;
    [self setModeSilently:ModeOff];
}
- (void)setModeSilently:(NSInteger)m {
    BOOL v = [D() boolForKey:@"notifyMode"]; [D() setBool:NO forKey:@"notifyMode"];
    [self setMode:m reason:nil]; [D() setBool:v forKey:@"notifyMode"];
}
- (void)pickTimer:(NSMenuItem *)i { [self startTimer:i.tag * 60.0]; }
- (void)customTimer {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *a = [[NSAlert alloc] init]; a.messageText = @"Set Timer"; a.informativeText = @"Minutes:";
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 160, 24)]; f.stringValue = @"45"; a.accessoryView = f;
    [a addButtonWithTitle:@"Start"]; [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] == NSAlertFirstButtonReturn && f.doubleValue > 0) [self startTimer:f.doubleValue * 60];
}
- (void)togglePause {
    if (!self.timerEnd) return;
    if (self.paused > 0) { self.timerEnd = [NSDate dateWithTimeIntervalSinceNow:self.paused]; self.paused = 0; [self scheduleFire]; }
    else { self.paused = MAX(1, [self remaining]); [self.fire invalidate]; self.fire = nil; }
    [self updateUI];
}
- (void)stopTimer { [self clearTimer]; [self updateUI]; }

#pragma mark - UI refresh
- (void)updateUI {
    NSButton *b = self.item.button;
    b.image = [self iconFor:self.mode];
    BOOL show = [D() boolForKey:@"showTimer"] && self.timerEnd;
    b.title = show ? [@" " stringByAppendingString:[self fmt:[self remaining]]] : @"";
    b.imagePosition = NSImageLeft;
    BOOL need = self.timerEnd && self.paused == 0 && (show || self.panel.visible);
    if (need && !self.ticker) {
        self.ticker = [NSTimer timerWithTimeInterval:1 target:self selector:@selector(updateUI) userInfo:nil repeats:YES];
        self.ticker.tolerance = 0.2; [NSRunLoop.mainRunLoop addTimer:self.ticker forMode:NSRunLoopCommonModes];
    } else if (!need && self.ticker) { [self.ticker invalidate]; self.ticker = nil; }
    if (self.panel) {
        self.seg.selectedSegment = self.mode;
        for (int i = 0; i < 3; i++) [self.seg setLabel:[self nameFor:i] forSegment:i];
        self.panelLabel.stringValue = self.timerEnd ? [NSString stringWithFormat:@"Timer: %@%@", [self fmt:[self remaining]], self.paused > 0 ? @" (paused)" : @""] : @"Timer: not set";
    }
}

#pragma mark - Notifications
- (void)notify:(NSString *)title body:(NSString *)body key:(NSString *)key {
    if (![D() boolForKey:key]) return;
    UNUserNotificationCenter *c = UNUserNotificationCenter.currentNotificationCenter;
    [c requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound completionHandler:^(BOOL ok, NSError *e) {
        if (!ok) return;
        UNMutableNotificationContent *n = [[UNMutableNotificationContent alloc] init]; n.title = title; n.body = body;
        [c addNotificationRequest:[UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString content:n trigger:nil] withCompletionHandler:nil];
    }];
}

#pragma mark - Rules
- (NSMutableDictionary *)rule:(NSString *)t { for (NSMutableDictionary *r in self.rules) if ([r[@"type"] isEqual:t]) return r; return nil; }
- (void)saveRules { [D() setObject:self.rules forKey:@"rules"]; [self scheduleShutoff]; }
- (void)scheduleShutoff {
    [self.shutoffTimer invalidate]; self.shutoffTimer = nil;
    NSDictionary *r = [self rule:@"shutoff"];
    if (!r || ![r[@"enabled"] boolValue] || self.mode == ModeOff) return;
    // Poll user idle time (keyboard/mouse/trackpad); fire once idle >= N hours.
    self.shutoffTimer = [NSTimer timerWithTimeInterval:30 target:self selector:@selector(shutoffCheck) userInfo:nil repeats:YES];
    self.shutoffTimer.tolerance = 15; [NSRunLoop.mainRunLoop addTimer:self.shutoffTimer forMode:NSRunLoopCommonModes];
}
- (void)shutoffCheck {
    NSDictionary *r = [self rule:@"shutoff"];
    if (!r || ![r[@"enabled"] boolValue] || self.mode == ModeOff) return;
    CFTimeInterval idle = CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateHIDSystemState, kCGAnyInputEventType);
    if (idle < 60) { self.shutoffFired = NO; return; }              // user is active again: re-arm
    if (self.shutoffFired || idle < [r[@"hours"] doubleValue] * 3600) return;
    self.shutoffFired = YES;                                         // fire once per idle period
    [self setMode:[r[@"action"] integerValue] reason:@"Safety auto-shutoff triggered (no user activity)."];
}
static void powerChanged(void *ctx) { [(__bridge App *)ctx checkBattery]; }
- (void)checkBattery {
    NSDictionary *r = [self rule:@"battery"];
    CFTypeRef info = IOPSCopyPowerSourcesInfo(); if (!info) return;
    NSArray *list = CFBridgingRelease(IOPSCopyPowerSourcesList(info)); CFRelease(info);
    for (id ps in list) {
        CFTypeRef info2 = IOPSCopyPowerSourcesInfo();
        NSDictionary *d = (__bridge NSDictionary *)IOPSGetPowerSourceDescription(info2, (__bridge CFTypeRef)ps);
        BOOL batt = [d[@kIOPSPowerSourceStateKey] isEqual:@kIOPSBatteryPowerValue];
        int pct = [d[@kIOPSCurrentCapacityKey] intValue];
        CFRelease(info2);
        if (batt && pct <= 20) {
            if (!self.lowBatteryFired && r && [r[@"enabled"] boolValue]) {
                self.lowBatteryFired = YES;
                [self setMode:[r[@"action"] integerValue] reason:@"Low battery rule triggered."];
            }
        } else self.lowBatteryFired = NO;
    }
}

#pragma mark - Panel (Window control mode)
- (void)showPanel {
    if (!self.panel) {
        NSWindow *w = self.panel = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 380, 120)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
        w.title = @"Coffee Buzz"; w.releasedWhenClosed = NO; w.delegate = self;
        self.seg = [NSSegmentedControl segmentedControlWithLabels:@[@"", @"", @""] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(segPicked:)];
        for (int i = 0; i < 3; i++) [self.seg setImage:[self iconFor:i] forSegment:i];
        self.seg.segmentStyle = NSSegmentStyleRounded;
        self.panelLabel = [NSTextField labelWithString:@""];
        NSButton *t = [NSButton buttonWithTitle:@"Set Timer ▾" target:self action:@selector(panelTimerMenu:)];
        NSButton *p = [NSButton buttonWithTitle:@"Pause/Resume" target:self action:@selector(togglePause)];
        NSButton *s = [NSButton buttonWithTitle:@"Stop" target:self action:@selector(stopTimer)];
        NSStackView *row = [NSStackView stackViewWithViews:@[t, p, s]];
        NSStackView *st = [NSStackView stackViewWithViews:@[self.seg, self.panelLabel, row]];
        st.orientation = NSUserInterfaceLayoutOrientationVertical; st.spacing = 10; st.edgeInsets = NSEdgeInsetsMake(14, 16, 14, 16);
        w.contentView = st; [w center];
    }
    [self updateUI];
    [NSApp activateIgnoringOtherApps:YES]; [self.panel makeKeyAndOrderFront:nil]; [self updateUI];
}
- (void)segPicked:(NSSegmentedControl *)s { [self setMode:s.selectedSegment reason:nil]; }
- (void)panelTimerMenu:(NSButton *)b { [self.mTimerRoot.submenu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, b.bounds.size.height) inView:b]; }
- (void)windowWillClose:(NSNotification *)n {
    if (n.object == self.prefs) { self.prefs = nil; self.rulesStack = nil; }
    else if (n.object == self.panel && [D() integerForKey:@"control"] == 1) {} 
    [self performSelector:@selector(updateUI) withObject:nil afterDelay:0];
}

#pragma mark - About / Quit
- (void)about { [NSApp activateIgnoringOtherApps:YES]; [NSApp orderFrontStandardAboutPanelWithOptions:@{@"ApplicationName": @"Coffee Buzz ARM"}]; }
- (void)quit { [NSApp terminate:nil]; }

#pragma mark - Preferences
- (NSButton *)check:(NSString *)t key:(NSString *)k {
    NSButton *b = [NSButton checkboxWithTitle:t target:self action:@selector(toggleKey:)];
    b.identifier = k; b.state = [D() boolForKey:k] ? NSControlStateValueOn : NSControlStateValueOff; return b;
}
- (void)toggleKey:(NSButton *)b {
    [D() setBool:b.state == NSControlStateValueOn forKey:b.identifier];
    if ([b.identifier isEqual:@"showTimer"] || [b.identifier isEqual:@"simple"]) [self updateUI];
}
- (NSStackView *)vstack:(NSArray *)v {
    NSStackView *s = [NSStackView stackViewWithViews:v]; s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeLeading; s.spacing = 12; s.edgeInsets = NSEdgeInsetsMake(18, 20, 18, 20); return s;
}
- (void)showPrefs {
    if (!self.prefs) {
        NSWindow *w = self.prefs = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 360)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        w.title = @"Preferences"; w.releasedWhenClosed = NO; w.delegate = self;
        NSTabView *tv = [[NSTabView alloc] init];

        // General
        NSMatrix *unused = nil; (void)unused;
        NSArray *ctl = @[@"Status bar menu", @"Window", @"Both"]; NSMutableArray *radios = [NSMutableArray array];
        for (NSUInteger i = 0; i < 3; i++) {
            NSButton *r = [NSButton radioButtonWithTitle:ctl[i] target:self action:@selector(controlPicked:)]; r.tag = i;
            r.state = [D() integerForKey:@"control"] == (NSInteger)i; [radios addObject:r];
        }
        NSStackView *rs = [self vstack:radios]; rs.edgeInsets = NSEdgeInsetsZero; rs.spacing = 6;
        NSStackView *ctlRow = [NSStackView stackViewWithViews:@[[NSTextField labelWithString:@"Control using:"], rs]]; ctlRow.alignment = NSLayoutAttributeTop;
        NSButton *dirs = [NSButton buttonWithTitle:@"Directions…" target:self action:@selector(directions)];
        NSStackView *moveRow = [NSStackView stackViewWithViews:@[[NSTextField labelWithString:@"Move status bar item:"], dirs]];
        NSButton *login = [NSButton checkboxWithTitle:@"Open at login" target:self action:@selector(toggleLogin:)];
        login.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
        NSStackView *gen = [self vstack:@[ctlRow, moveRow, login, [self check:@"Use simple mode names" key:@"simple"],
            [self check:@"Right-click the status icon to switch modes" key:@"rightClick"],
            [self check:@"Show timer next to status icon when running" key:@"showTimer"]]];
        NSTabViewItem *t1 = [[NSTabViewItem alloc] init]; t1.label = @"General"; t1.view = gen; [tv addTabViewItem:t1];

        // Rules
        self.rulesStack = [self vstack:@[]]; 
        NSButton *add = [NSButton buttonWithTitle:@"+ Add Rule" target:self action:@selector(addRule:)]; add.bordered = NO;
        NSStackView *rv = [self vstack:@[self.rulesStack, add]];
        NSTabViewItem *t2 = [[NSTabViewItem alloc] init]; t2.label = @"Rules"; t2.view = rv; [tv addTabViewItem:t2];
        [self rebuildRules];

        // Notifications
        NSStackView *nt = [self vstack:@[[NSTextField labelWithString:@"Show notifications:"], [self check:@"At startup" key:@"notifyStart"],
            [self check:@"When you change the mode" key:@"notifyMode"], [self check:@"When the timer completes" key:@"notifyTimer"],
            [self check:@"When rules are triggered" key:@"notifyRules"]]];
        NSTabViewItem *t3 = [[NSTabViewItem alloc] init]; t3.label = @"Notifications"; t3.view = nt; [tv addTabViewItem:t3];

        w.contentView = tv; [w center];
    }
    [NSApp activateIgnoringOtherApps:YES]; [self.prefs makeKeyAndOrderFront:nil];
}
- (void)controlPicked:(NSButton *)b {
    [D() setInteger:b.tag forKey:@"control"];
    for (NSView *v in b.superview.subviews) if ([v isKindOfClass:NSButton.class]) ((NSButton *)v).state = ((NSButton *)v).tag == b.tag;
    [self applyControlMode];
}
- (void)directions {
    NSAlert *a = [[NSAlert alloc] init]; a.messageText = @"Move the status bar item";
    a.informativeText = @"Hold the ⌘ (Command) key and drag the Coffee Buzz icon in the menu bar left or right to the position you want."; [a runModal];
}
- (void)toggleLogin:(NSButton *)b {
    NSError *e = nil;
    if (b.state == NSControlStateValueOn) [SMAppService.mainAppService registerAndReturnError:&e];
    else [SMAppService.mainAppService unregisterAndReturnError:&e];
    if (e) { NSAlert *a = [NSAlert alertWithError:e]; [a runModal]; b.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled; }
}
- (NSPopUpButton *)modePopup:(NSInteger)sel tag:(NSInteger)tag {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (int i = 0; i < 3; i++) { [p addItemWithTitle:[@"Switch to " stringByAppendingString:[self nameFor:i]]]; p.lastItem.image = [self iconFor:i]; }
    [p selectItemAtIndex:sel]; p.tag = tag; p.target = self; p.action = @selector(ruleAction:); return p;
}
- (void)rebuildRules {
    for (NSView *v in [self.rulesStack.arrangedSubviews copy]) { [self.rulesStack removeArrangedSubview:v]; [v removeFromSuperview]; }
    for (NSUInteger i = 0; i < self.rules.count; i++) {
        NSDictionary *r = self.rules[i]; BOOL bat = [r[@"type"] isEqual:@"battery"];
        NSButton *c = [NSButton checkboxWithTitle:bat ? @"Low Battery Warning (≤ 20%)" : @"Safety Auto-Shutoff:" target:self action:@selector(ruleEnable:)];
        c.tag = i; c.state = [r[@"enabled"] boolValue];
        NSMutableArray *rowViews = [NSMutableArray arrayWithObject:c];
        if (!bat) {
            NSPopUpButton *h = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
            for (NSNumber *n in @[@1, @2, @3, @4, @6, @8, @12]) [h addItemWithTitle:[NSString stringWithFormat:@"%@ hour%@", n, n.intValue > 1 ? @"s" : @""]];
            NSUInteger idx = [@[@1, @2, @3, @4, @6, @8, @12] indexOfObject:r[@"hours"]]; [h selectItemAtIndex:idx == NSNotFound ? 2 : idx];
            h.tag = i; h.target = self; h.action = @selector(ruleHours:); [rowViews addObject:h];
        }
        NSButton *x = [NSButton buttonWithTitle:@"✕" target:self action:@selector(ruleDelete:)]; x.bordered = NO; x.tag = i; [rowViews addObject:x];
        NSStackView *row = [NSStackView stackViewWithViews:rowViews];
        [self.rulesStack addArrangedSubview:row];
        [self.rulesStack addArrangedSubview:[self modePopup:[r[@"action"] integerValue] tag:i]];
    }
}
- (void)ruleEnable:(NSButton *)b { self.rules[b.tag][@"enabled"] = @(b.state == NSControlStateValueOn); [self saveRules]; }
- (void)ruleHours:(NSPopUpButton *)p { self.rules[p.tag][@"hours"] = @([[p.selectedItem.title componentsSeparatedByString:@" "].firstObject intValue]); [self saveRules]; }
- (void)ruleAction:(NSPopUpButton *)p { self.rules[p.tag][@"action"] = @(p.indexOfSelectedItem); [self saveRules]; }
- (void)ruleDelete:(NSButton *)b { [self.rules removeObjectAtIndex:b.tag]; [self saveRules]; [self rebuildRules]; }
- (void)addRule:(NSButton *)b {
    NSMenu *m = [[NSMenu alloc] init];
    if (![self rule:@"battery"]) { NSMenuItem *i = [self add:@"Low Battery Warning" sel:@selector(addRuleType:) to:m]; i.representedObject = @"battery"; }
    if (![self rule:@"shutoff"]) { NSMenuItem *i = [self add:@"Safety Auto-Shutoff" sel:@selector(addRuleType:) to:m]; i.representedObject = @"shutoff"; }
    if (!m.numberOfItems) return;
    [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, b.bounds.size.height) inView:b];
}
- (void)addRuleType:(NSMenuItem *)i {
    [self.rules addObject:[@{@"type": i.representedObject, @"enabled": @YES, @"action": @0, @"hours": @3} mutableCopy]];
    [self saveRules]; [self rebuildRules];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        static App *d; d = [[App alloc] init]; app.delegate = d;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
