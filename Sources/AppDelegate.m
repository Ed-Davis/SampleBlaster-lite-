#import "AppDelegate.h"
#import "SBDisk.h"
#import "SBTransfer.h"
#import <objc/runtime.h>

#pragma mark - Drop target

/// The window's content: accepts a disk image (to mount it) or, once one is
/// mounted, files and folders to add.
@interface SBDropView : NSView
@property (nonatomic, copy) BOOL (^canAccept)(NSArray<NSURL *> *urls);
@property (nonatomic, copy) void (^didDrop)(NSArray<NSURL *> *urls);
@end

@implementation SBDropView {
    BOOL _highlighted;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    }
    return self;
}

- (NSArray<NSURL *> *)fileURLsFrom:(id<NSDraggingInfo>)info {
    return [info.draggingPasteboard readObjectsForClasses:@[NSURL.class]
                                                  options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}] ?: @[];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
    NSArray *urls = [self fileURLsFrom:info];
    BOOL ok = urls.count && self.canAccept && self.canAccept(urls);
    _highlighted = ok;
    self.needsDisplay = YES;
    return ok ? NSDragOperationCopy : NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)info {
    _highlighted = NO;
    self.needsDisplay = YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    _highlighted = NO;
    self.needsDisplay = YES;
    NSArray *urls = [self fileURLsFrom:info];
    if (!urls.count || !self.didDrop) return NO;
    self.didDrop(urls);
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (_highlighted) {
        [[NSColor.selectedControlColor colorWithAlphaComponent:0.8] setStroke];
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 3, 3) xRadius:8 yRadius:8];
        path.lineWidth = 4;
        [path stroke];
    }
}

@end

#pragma mark - Version and copyright

static NSString * const SBCopyright = @"Copyright Ed Davis 2026";

/// "Version 1.0 beta (build 12)". Always marked beta: this app can't be
/// tested on a real High Sierra Mac before release.
static NSString *SBVersionLine(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"1.0";
    NSString *build = info[@"CFBundleVersion"] ?: @"1";
    return [NSString stringWithFormat:@"Version %@ beta (build %@)", version, build];
}

#pragma mark - Splash screen

/// The artwork, with the copyright, version and build drawn over it. Shown
/// for a moment at launch; a click dismisses it sooner.
@interface SBSplash : NSObject
+ (void)showThen:(void (^)(void))done;
@end

@implementation SBSplash

static NSWindow *sSplashWindow;

+ (void)showThen:(void (^)(void))done {
    NSImage *image = [NSImage imageNamed:@"Splash"];
    if (!image || image.size.width <= 0) { done(); return; }
    CGFloat width = 640, height = round(width * image.size.height / image.size.width);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    window.backgroundColor = NSColor.blackColor;
    window.hasShadow = YES;
    window.level = NSFloatingWindowLevel;

    NSImageView *imageView = [NSImageView imageViewWithImage:image];
    imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    imageView.frame = NSMakeRect(0, 0, width, height);
    [window.contentView addSubview:imageView];

    NSTextField *overlay = [NSTextField labelWithString:[NSString stringWithFormat:@"%@  ·  %@", SBCopyright, SBVersionLine()]];
    overlay.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    overlay.textColor = [NSColor colorWithWhite:1 alpha:0.92];
    overlay.alignment = NSTextAlignmentCenter;
    overlay.drawsBackground = NO;
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.9];
    shadow.shadowBlurRadius = 3;
    shadow.shadowOffset = NSMakeSize(0, -1);
    overlay.shadow = shadow;
    overlay.frame = NSMakeRect(0, 16, width, 20);
    [window.contentView addSubview:overlay];

    __block BOOL finished = NO;
    void (^finish)(void) = ^{
        if (finished) return;
        finished = YES;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.35;
            window.animator.alphaValue = 0;
        } completionHandler:^{
            [window orderOut:nil];
            sSplashWindow = nil;
        }];
        done();
    };
    NSClickGestureRecognizer *click = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(clicked:)];
    [imageView addGestureRecognizer:click];
    objc_setAssociatedObject(self, @selector(clicked:), finish, OBJC_ASSOCIATION_COPY);

    sSplashWindow = window;
    [window center];
    [window orderFront:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), finish);
}

+ (void)clicked:(id)sender {
    void (^finish)(void) = objc_getAssociatedObject(self, @selector(clicked:));
    if (finish) finish();
}

@end

#pragma mark - App

@interface AppDelegate () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation AppDelegate {
    NSWindow *_window;
    NSTextField *_imageLabel;
    NSTextField *_pathLabel;
    NSTextField *_statusLabel;
    NSTextField *_hintLabel;
    NSButton *_openButton;
    NSButton *_ejectButton;
    NSButton *_upButton;
    NSButton *_addButton;
    NSButton *_ejectCardCheckbox;
    NSPopUpButton *_partitionPopup;
    NSProgressIndicator *_spinner;
    NSTableView *_table;

    SBMountedImage *_mounted;
    NSUInteger _partitionIndex;
    NSURL *_currentFolder;
    NSArray<NSDictionary *> *_entries;   // name, isFolder, size
    BOOL _busy;
    BOOL _quitAfterEject;
    dispatch_queue_t _work;
}

#pragma mark Launch

- (void)applicationWillFinishLaunching:(NSNotification *)note {
    _work = dispatch_queue_create("SampleBlasterLite.work", DISPATCH_QUEUE_SERIAL);
    _entries = @[];
    [self buildMenu];
    [self buildWindow];
    [self updateUI];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [NSApp activateIgnoringOtherApps:YES];
    [SBSplash showThen:^{
        [self->_window makeKeyAndOrderFront:nil];
    }];
}

- (IBAction)showAbout:(id)sender {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    [NSApp orderFrontStandardAboutPanelWithOptions:@{
        @"ApplicationVersion": [NSString stringWithFormat:@"%@ beta", info[@"CFBundleShortVersionString"] ?: @"1.0"],
        @"Version": [NSString stringWithFormat:@"build %@", info[@"CFBundleVersion"] ?: @"1"],
        @"Copyright": SBCopyright,
    }];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app {
    return YES;
}

/// Double-clicking an image in Finder, or dropping it on the app icon.
- (BOOL)application:(NSApplication *)app openFile:(NSString *)filename {
    NSURL *url = [NSURL fileURLWithPath:filename];
    if (![SBDisk isDiskImage:url]) return NO;
    if (_mounted || _busy) {
        [self setStatus:@"Eject the current image first, then open another."];
        return NO;
    }
    [self mountImage:url];
    return YES;
}

/// Never leave an image attached: eject it (cleanly) before quitting.
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
    if (_busy) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"SampleBlaster Lite is still working.";
        alert.informativeText = @"Wait for it to finish, then quit.";
        [alert runModal];
        return NSTerminateCancel;
    }
    if (_mounted) {
        _quitAfterEject = YES;
        [self eject:nil];
        return NSTerminateLater;
    }
    return NSTerminateNow;
}

#pragma mark Building the UI

- (void)buildMenu {
    NSMenu *bar = [[NSMenu alloc] init];
    NSString *appName = @"SampleBlaster Lite";

    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];
    [appMenu addItemWithTitle:[@"About " stringByAppendingString:appName]
                       action:@selector(showAbout:) keyEquivalent:@""].target = self;
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItemWithTitle:[@"Hide " stringByAppendingString:appName] action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItemWithTitle:[@"Quit " stringByAppendingString:appName] action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [bar addItem:appItem];

    NSMenuItem *fileItem = [[NSMenuItem alloc] init];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"Open Disk Image…" action:@selector(openImage:) keyEquivalent:@"o"].target = self;
    [fileMenu addItemWithTitle:@"Add Files…" action:@selector(addFiles:) keyEquivalent:@"a"].target = self;
    fileMenu.itemArray.lastObject.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [fileMenu addItemWithTitle:@"Eject" action:@selector(eject:) keyEquivalent:@"e"].target = self;
    [fileMenu addItem:NSMenuItem.separatorItem];
    [fileMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
    fileItem.submenu = fileMenu;
    [bar addItem:fileItem];

    NSMenuItem *windowItem = [[NSMenuItem alloc] init];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    windowItem.submenu = windowMenu;
    [bar addItem:windowItem];
    NSApp.windowsMenu = windowMenu;

    NSApp.mainMenu = bar;
}

- (NSTextField *)label:(NSString *)text font:(NSFont *)font {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = font;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

- (NSButton *)button:(NSString *)title action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.bezelStyle = NSBezelStyleRounded;
    return button;
}

- (void)buildWindow {
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 520)
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                    NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                            backing:NSBackingStoreBuffered defer:NO];
    // The title bar carries the copyright, version and build.
    _window.title = [NSString stringWithFormat:@"SampleBlaster Lite  —  %@  —  %@", SBCopyright, SBVersionLine()];
    _window.contentMinSize = NSMakeSize(560, 420);
    _window.releasedWhenClosed = NO;
    [_window center];
    [_window setFrameAutosaveName:@"Main"];

    SBDropView *content = [[SBDropView alloc] initWithFrame:NSZeroRect];
    __weak AppDelegate *weakSelf = self;
    content.canAccept = ^BOOL(NSArray<NSURL *> *urls) {
        AppDelegate *s = weakSelf;
        if (!s || s->_busy) return NO;
        if (s->_mounted) return YES;
        return urls.count == 1 && [SBDisk isDiskImage:urls.firstObject];
    };
    content.didDrop = ^(NSArray<NSURL *> *urls) {
        AppDelegate *s = weakSelf;
        if (!s) return;
        if (s->_mounted) [s addURLs:urls];
        else [s mountImage:urls.firstObject];
    };
    _window.contentView = content;

    // Optional artwork across the top (Header.png in the app's Resources).
    NSView *header;
    NSImage *headerImage = [NSImage imageNamed:@"Header"];
    if (headerImage) {
        NSImageView *imageView = [NSImageView imageViewWithImage:headerImage];
        imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
        [imageView setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [imageView.heightAnchor constraintEqualToConstant:MIN(120, headerImage.size.height)].active = YES;
        header = imageView;
    } else {
        header = [self label:@"SampleBlaster Lite" font:[NSFont boldSystemFontOfSize:20]];
    }

    _openButton = [self button:@"Open Disk Image…" action:@selector(openImage:)];
    _ejectButton = [self button:@"Eject" action:@selector(eject:)];
    _imageLabel = [self label:@"" font:[NSFont systemFontOfSize:NSFont.systemFontSize]];
    NSStackView *imageRow = [NSStackView stackViewWithViews:@[_openButton, _imageLabel, _ejectButton]];
    [_imageLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    _partitionPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _partitionPopup.target = self;
    _partitionPopup.action = @selector(choosePartition:);
    _upButton = [self button:@"Up" action:@selector(goUp:)];
    _pathLabel = [self label:@"" font:[NSFont systemFontOfSize:NSFont.smallSystemFontSize]];
    _pathLabel.textColor = NSColor.secondaryLabelColor;
    NSStackView *pathRow = [NSStackView stackViewWithViews:@[_partitionPopup, _upButton, _pathLabel]];

    _table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameColumn.title = @"Name";
    nameColumn.width = 300;
    NSTableColumn *sizeColumn = [[NSTableColumn alloc] initWithIdentifier:@"size"];
    sizeColumn.title = @"Size";
    sizeColumn.width = 100;
    [_table addTableColumn:nameColumn];
    [_table addTableColumn:sizeColumn];
    _table.dataSource = self;
    _table.delegate = self;
    _table.target = self;
    _table.doubleAction = @selector(openRow:);
    _table.usesAlternatingRowBackgroundColors = YES;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.documentView = _table;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    [scroll setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];

    _addButton = [self button:@"Add Files…" action:@selector(addFiles:)];
    _hintLabel = [self label:@"" font:[NSFont systemFontOfSize:NSFont.smallSystemFontSize]];
    _hintLabel.textColor = NSColor.secondaryLabelColor;
    NSStackView *addRow = [NSStackView stackViewWithViews:@[_addButton, _hintLabel]];

    _ejectCardCheckbox = [NSButton checkboxWithTitle:@"Also eject the SD card when I eject the image" target:nil action:nil];
    _ejectCardCheckbox.state = NSControlStateValueOn;

    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.displayedWhenStopped = NO;
    _statusLabel = [self label:@"Choose a ZuluSCSI disk image (.img or .hda) to begin." font:[NSFont systemFontOfSize:NSFont.smallSystemFontSize]];
    NSStackView *statusRow = [NSStackView stackViewWithViews:@[_spinner, _statusLabel]];

    NSStackView *stack = [NSStackView stackViewWithViews:@[header, imageRow, pathRow, scroll, addRow, _ejectCardCheckbox, statusRow]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.edgeInsets = NSEdgeInsetsMake(16, 16, 16, 16);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    ]];
    for (NSView *row in @[imageRow, pathRow, scroll, addRow, statusRow]) {
        [row.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-32].active = YES;
    }
    if (headerImage) [header.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-32].active = YES;
    [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:180].active = YES;
}

#pragma mark State

- (NSString *)sizeText:(unsigned long long)bytes {
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
}

- (NSURL *)currentRoot {
    return _mounted && _partitionIndex < _mounted.mountPoints.count ? _mounted.mountPoints[_partitionIndex] : nil;
}

- (void)setStatus:(NSString *)text {
    _statusLabel.stringValue = text ?: @"";
}

- (void)setBusy:(BOOL)busy status:(NSString *)status {
    _busy = busy;
    if (busy) [_spinner startAnimation:nil]; else [_spinner stopAnimation:nil];
    if (status) [self setStatus:status];
    [self updateUI];
}

- (void)updateUI {
    BOOL mounted = _mounted != nil;
    _openButton.enabled = !_busy && !mounted;
    _ejectButton.enabled = !_busy && mounted;
    _addButton.enabled = !_busy && mounted;
    _table.enabled = !_busy && mounted;
    NSURL *root = [self currentRoot];
    _upButton.enabled = !_busy && mounted && _currentFolder && ![_currentFolder.path isEqualToString:root.path];
    _partitionPopup.hidden = !mounted || _mounted.mountPoints.count < 2;
    _partitionPopup.enabled = !_busy;
    _upButton.hidden = !mounted;

    if (mounted) {
        NSNumber *free = nil;
        [root getResourceValue:&free forKey:NSURLVolumeAvailableCapacityKey error:NULL];
        _imageLabel.stringValue = [NSString stringWithFormat:@"%@ — %@ free",
                                   _mounted.imageURL.lastPathComponent, free ? [self sizeText:free.unsignedLongLongValue] : @"?"];
        NSString *relative = [_currentFolder.path substringFromIndex:MIN(root.path.length, _currentFolder.path.length)];
        _pathLabel.stringValue = [NSString stringWithFormat:@"%@%@", root.lastPathComponent, relative.length ? relative : @"/"];
        _hintLabel.stringValue = @"or drag files and folders onto this window";
    } else {
        _imageLabel.stringValue = @"No disk image open";
        _pathLabel.stringValue = @"";
        _hintLabel.stringValue = @"Open a disk image first (or drag one onto this window)";
    }
}

- (void)reloadFolder {
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    if (_currentFolder) {
        NSArray<NSURL *> *urls = [NSFileManager.defaultManager contentsOfDirectoryAtURL:_currentFolder
                                       includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLFileSizeKey]
                                                          options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL] ?: @[];
        for (NSURL *url in urls) {
            if ([url.lastPathComponent hasPrefix:@"."]) continue;   // FAT doesn't always honour "hidden"
            NSNumber *isDir = nil, *size = nil;
            [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:NULL];
            [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
            [entries addObject:@{@"url": url, @"name": url.lastPathComponent,
                                 @"folder": @(isDir.boolValue), @"size": size ?: @0}];
        }
        [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            if ([a[@"folder"] boolValue] != [b[@"folder"] boolValue]) return [a[@"folder"] boolValue] ? NSOrderedAscending : NSOrderedDescending;
            return [a[@"name"] localizedStandardCompare:b[@"name"]];
        }];
    }
    _entries = entries;
    [_table reloadData];
    [self updateUI];
}

- (void)showAlert:(NSString *)title text:(NSString *)text {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = text ?: @"";
    [alert beginSheetModalForWindow:_window completionHandler:nil];
}

#pragma mark Mounting and ejecting

- (IBAction)openImage:(id)sender {
    if (_busy || _mounted) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes = @[@"img", @"hda", @"hdd", @"IMG", @"HDA", @"HDD"];
    panel.allowsMultipleSelection = NO;
    panel.message = @"Choose a ZuluSCSI disk image";
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) [self mountImage:panel.URL];
    }];
}

- (void)mountImage:(NSURL *)url {
    if (_busy || _mounted || !url) return;
    [self setBusy:YES status:[NSString stringWithFormat:@"Mounting %@…", url.lastPathComponent]];
    dispatch_async(_work, ^{
        NSError *error = nil;
        SBMountedImage *image = [SBDisk attachImageAtURL:url error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!image) {
                [self setBusy:NO status:error.localizedDescription];
                [self showAlert:@"Couldn't open the disk image" text:error.localizedDescription];
                return;
            }
            self->_mounted = image;
            self->_partitionIndex = 0;
            self->_currentFolder = image.mountPoints.firstObject;
            [self->_partitionPopup removeAllItems];
            for (NSUInteger i = 0; i < image.mountPoints.count; i++) {
                [self->_partitionPopup addItemWithTitle:[NSString stringWithFormat:@"Partition %lu: %@",
                                                         (unsigned long)(i + 1), image.mountPoints[i].lastPathComponent]];
            }
            [self setBusy:NO status:[NSString stringWithFormat:@"Opened %@%@. Add files, then Eject.", url.lastPathComponent,
                                     image.mountPoints.count > 1 ? [NSString stringWithFormat:@" (%lu partitions)", (unsigned long)image.mountPoints.count] : @""]];
            [self reloadFolder];
        });
    });
}

- (IBAction)eject:(id)sender {
    if (_busy || !_mounted) {
        if (_quitAfterEject && !_mounted) [NSApp replyToApplicationShouldTerminate:YES];
        return;
    }
    SBMountedImage *image = _mounted;
    BOOL ejectCard = _ejectCardCheckbox.state == NSControlStateValueOn;
    [self setBusy:YES status:[NSString stringWithFormat:@"Ejecting %@…", image.imageURL.lastPathComponent]];
    dispatch_async(_work, ^{
        NSError *error = nil;
        BOOL ok = [SBDisk ejectImage:image error:&error];
        NSString *cardNote = @"";
        if (ok && ejectCard) cardNote = [self ejectCardHolding:image.imageURL];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) {
                [self setBusy:NO status:error.localizedDescription];
                if (self->_quitAfterEject) {
                    self->_quitAfterEject = NO;
                    [NSApp replyToApplicationShouldTerminate:NO];
                }
                [self showAlert:@"Couldn't eject the disk image" text:error.localizedDescription];
                return;
            }
            self->_mounted = nil;
            self->_currentFolder = nil;
            [self->_partitionPopup removeAllItems];
            [self setBusy:NO status:[NSString stringWithFormat:@"Ejected %@.%@", image.imageURL.lastPathComponent, cardNote]];
            [self reloadFolder];
            if (self->_quitAfterEject) [NSApp replyToApplicationShouldTerminate:YES];
        });
    });
}

/// Ejects the card the image lives on, if it's removable media. Returns a
/// note for the status line.
- (NSString *)ejectCardHolding:(NSURL *)imageURL {
    NSURL *volume = nil;
    NSNumber *ejectable = nil, *removable = nil, *internal = nil;
    [imageURL getResourceValue:&volume forKey:NSURLVolumeURLKey error:NULL];
    if (!volume || [volume.path isEqualToString:@"/"]) return @"";
    [volume getResourceValue:&ejectable forKey:NSURLVolumeIsEjectableKey error:NULL];
    [volume getResourceValue:&removable forKey:NSURLVolumeIsRemovableKey error:NULL];
    [volume getResourceValue:&internal forKey:NSURLVolumeIsInternalKey error:NULL];
    if (!(ejectable.boolValue || removable.boolValue) && internal.boolValue) return @"";
    NSError *error = nil;
    if ([NSWorkspace.sharedWorkspace unmountAndEjectDeviceAtURL:volume error:&error]) {
        return @" The SD card is ejected too: safe to remove.";
    }
    return @" The SD card didn't eject: eject it in Finder before removing it.";
}

#pragma mark Browsing

- (IBAction)choosePartition:(id)sender {
    NSInteger index = _partitionPopup.indexOfSelectedItem;
    if (!_mounted || index < 0 || (NSUInteger)index >= _mounted.mountPoints.count) return;
    _partitionIndex = (NSUInteger)index;
    _currentFolder = _mounted.mountPoints[_partitionIndex];
    [self reloadFolder];
}

- (IBAction)goUp:(id)sender {
    NSURL *root = [self currentRoot];
    if (!_currentFolder || !root || [_currentFolder.path isEqualToString:root.path]) return;
    _currentFolder = _currentFolder.URLByDeletingLastPathComponent;
    [self reloadFolder];
}

- (IBAction)openRow:(id)sender {
    NSInteger row = _table.clickedRow;
    if (_busy || row < 0 || (NSUInteger)row >= _entries.count) return;
    NSDictionary *entry = _entries[(NSUInteger)row];
    if (![entry[@"folder"] boolValue]) return;
    _currentFolder = entry[@"url"];
    [self reloadFolder];
}

#pragma mark Adding files

- (IBAction)addFiles:(id)sender {
    if (_busy || !_mounted) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = YES;
    panel.prompt = @"Add";
    panel.message = @"Choose samples, MPC files or folders to add (they're copied exactly as they are)";
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) [self addURLs:panel.URLs];
    }];
}

- (void)addURLs:(NSArray<NSURL *> *)urls {
    NSURL *folder = _currentFolder;
    if (_busy || !_mounted || !folder || !urls.count) return;
    [self setBusy:YES status:@"Adding files…"];
    dispatch_async(_work, ^{
        NSArray<NSString *> *results = [SBTransfer addItems:urls toFolder:folder progress:^(NSString *name) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self setStatus:[@"Adding " stringByAppendingString:name]]; });
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSUInteger skipped = 0;
            for (NSString *line in results) if ([line containsString:@": skipped"]) skipped++;
            NSUInteger added = results.count - skipped;
            [self setBusy:NO status:[NSString stringWithFormat:@"Added %lu item%@%@.", (unsigned long)added, added == 1 ? @"" : @"s",
                                     skipped ? [NSString stringWithFormat:@", skipped %lu", (unsigned long)skipped] : @""]];
            [self reloadFolder];
            if (skipped) {
                NSArray *shown = results.count > 25 ? [results subarrayWithRange:NSMakeRange(0, 25)] : results;
                [self showAlert:[NSString stringWithFormat:@"%lu item%@ couldn't be added", (unsigned long)skipped, skipped == 1 ? @"" : @"s"]
                           text:[shown componentsJoinedByString:@"\n"]];
            }
        });
    });
}

#pragma mark Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_entries.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSTextField *cell = [tableView makeViewWithIdentifier:column.identifier owner:self];
    if (!cell) {
        cell = [NSTextField labelWithString:@""];
        cell.identifier = column.identifier;
        cell.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    NSDictionary *entry = _entries[(NSUInteger)row];
    BOOL folder = [entry[@"folder"] boolValue];
    if ([column.identifier isEqualToString:@"name"]) {
        cell.stringValue = folder ? [entry[@"name"] stringByAppendingString:@"/"] : entry[@"name"];
        cell.font = folder ? [NSFont boldSystemFontOfSize:NSFont.systemFontSize] : [NSFont systemFontOfSize:NSFont.systemFontSize];
    } else {
        cell.stringValue = folder ? @"Folder" : [self sizeText:[entry[@"size"] unsignedLongLongValue]];
        cell.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
    }
    return cell;
}

@end
