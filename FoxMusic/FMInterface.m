//
//  FMInterface.m
//  Retrofy
//
//  The app's interface: the Slint screens (FMLibrespot/ui/app.slint) in an OpenGL ES 2 layer, on top of the Canvas
//  clip. This hands them what to show and acts on what the user does, the Spotify and playback code stays as it was.
//

#import "FMInterface.h"

#import <MediaPlayer/MediaPlayer.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <QuartzCore/QuartzCore.h>

#import "FMAppDelegate.h"
#import "FMCanvasView.h"
#import "FMDJSession.h"
#import "FMPlayer.h"
#import "FMSpotifyContent.h"
#import "FMSpotifyLibrary.h"
#import "fmui.h"

// Pictures in lists, in pixels. Now Playing's is bigger.
static const CGFloat FMInterfaceThumbnailSize = 200;
static const CGFloat FMInterfaceCoverSize = 640;
static const NSUInteger FMInterfaceMaximumCoverLoads = 4;
// Shelves show again from what's loaded, and refresh when they're this old.
static const NSTimeInterval FMInterfaceRefreshInterval = 600;
// Tracks per librespot request, each one is looked up separately.
static const NSUInteger FMInterfacePlaylistPageSize = 50;
// Rows to look up the Liked Songs state of, from the top of the visible ones.
static const NSUInteger FMInterfaceVisibleRows = 30;
// Lines light up a little early, like in Spotify.
static const NSTimeInterval FMInterfaceLyricsLeadTime = 0.15;

// Where SearchPage in app.slint has its field, in points.
static const CGFloat FMInterfaceSearchFieldX = 54;
static const CGFloat FMInterfaceSearchFieldY = 82;
static const CGFloat FMInterfaceSearchFieldHeight = 42;

static EAGLContext *FMContext;
static GLuint FMColourBuffer;

static void FMPresent(void)
{
    // femtovg unbinds renderbuffers when it makes a shadow's stencil.
    glBindRenderbuffer(GL_RENDERBUFFER, FMColourBuffer);
    [FMContext presentRenderbuffer:GL_RENDERBUFFER];
}

static void FMLog(const char *message)
{
    NSLog(@"Slint: %s", message);
}

@interface FMInterface ()
- (void)handleAction:(NSString *)name index:(int)index text:(NSString *)text;
- (void)viewTouched;
@end

static void FMAction(const char *name, int index, const char *text)
{
    [[FMInterface sharedInterface] handleAction:[NSString stringWithUTF8String:name] index:index text:[NSString stringWithUTF8String:text]];
}

// The Slint screens' OpenGL layer.
@interface FMGLView : UIView
{
    GLuint _framebuffer, _stencilBuffer;
    CADisplayLink *_displayLink;
}
- (BOOL)start;
@end

@implementation FMGLView

+ (Class)layerClass
{
    return [CAEAGLLayer class];
}

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.multipleTouchEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentScaleFactor = [UIScreen mainScreen].scale;
        CAEAGLLayer *layer = (CAEAGLLayer *)self.layer;
        layer.opaque = NO;
        layer.drawableProperties = @{kEAGLDrawablePropertyRetainedBacking: @NO, kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8};
        for (NSString *name in @[UIApplicationDidEnterBackgroundNotification, UIApplicationWillEnterForegroundNotification]) {
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationStateDidChange:) name:name object:nil];
        }
    }
    return self;
}

- (BOOL)start
{
    FMContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    [EAGLContext setCurrentContext:FMContext];

    glGenFramebuffers(1, &_framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);

    glGenRenderbuffers(1, &FMColourBuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, FMColourBuffer);
    [FMContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)self.layer];
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, FMColourBuffer);

    GLint width = 0, height = 0;
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &width);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &height);

    glGenRenderbuffers(1, &_stencilBuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _stencilBuffer);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8_OES, width, height);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _stencilBuffer);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, _stencilBuffer);

    NSLog(@"Interface: %s, %s, %dx%d", glGetString(GL_VERSION), glGetString(GL_RENDERER), width, height);
    if (fm_ui_start(_framebuffer, width, height, self.contentScaleFactor, FMPresent, FMLog, FMAction) != 0) return NO;

    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    return YES;
}

- (void)tick
{
    [EAGLContext setCurrentContext:FMContext];
    fm_ui_tick();
}

// iOS kills an app that uses OpenGL in the background.
- (void)applicationStateDidChange:(NSNotification *)notification
{
    BOOL inBackground = [notification.name isEqualToString:UIApplicationDidEnterBackgroundNotification];
    _displayLink.paused = inBackground;
    if (inBackground) glFinish();
}

- (void)touch:(NSSet *)touches phase:(int)phase
{
    CGPoint point = [[touches anyObject] locationInView:self];
    if (phase == 0) [[FMInterface sharedInterface] viewTouched];
    fm_ui_touch(phase, point.x, point.y);
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event { [self touch:touches phase:0]; }
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event { [self touch:touches phase:1]; }
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event { [self touch:touches phase:2]; }
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event { [self touch:touches phase:3]; }

@end

@interface FMInterface ()
{
    FMGLView *_glView;
    FMCanvasView *_canvasView;
    UITextField *_searchField;
    NSTimer *_progressTimer;

    // Playlists on the screens, by the keys sent with them.
    NSMutableDictionary *_playlists;
    FMSpotifyPlaylistArray *_webPlaylists;
    NSArray *_pickerPlaylists;
    NSDate *_lastLoad;
    BOOL _isLoading;

    NSMutableSet *_requestedCovers;
    NSMutableArray *_coverQueue;
    NSUInteger _coverLoads;

    FMSpotifyPlaylist *_openPlaylist;
    FMSpotifyPlaylist *_likedSongs;
    // Tracks of _openPlaylist that were sent.
    NSUInteger _sentTracks;
    NSUInteger _visibleTrack;
    FMSpotifyTrackArray *_searchResults;
    NSMutableSet *_librespotLoadingPlaylists;

    BOOL _nowPlayingOpen;
    BOOL _hasVideo;
    UIImage *_sentCover;
    NSString *_tint;
    BOOL _hasLyrics;
    // The track that lyrics and the Canvas were looked up for, and whose Liked Songs state was asked for.
    FMSpotifyTrack *_lookedUpTrack;
    FMSpotifyTrack *_checkedTrack;
    NSArray *_lyricStartTimes;
    BOOL _lyricsSynced;

    // What the open action sheet or alert is about.
    FMSpotifyTrack *_actionTrack;

    MPMusicPlayerController *_volumeController;
}
@end

@implementation FMInterface

+ (FMInterface *)sharedInterface
{
    static FMInterface *sharedInterface;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInterface = [[FMInterface alloc] init];
    });
    return sharedInterface;
}

- (FMAppDelegate *)appDelegate
{
    return (FMAppDelegate *)[[UIApplication sharedApplication] delegate];
}

- (FMSpotifyClient *)client
{
    return [[self appDelegate] spotifyClient];
}

- (void)send:(NSString *)kind :(id)object
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self send:kind :object];
        });
        return;
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) {
        NSLog(@"Interface: couldn't send %@", kind);
        return;
    }
    NSString *string = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    fm_ui_send([kind UTF8String], [string UTF8String]);
}

- (void)show
{
    _playlists = [NSMutableDictionary dictionary];
    _requestedCovers = [NSMutableSet set];
    _coverQueue = [NSMutableArray array];
    _librespotLoadingPlaylists = [NSMutableSet set];

    CGRect bounds = [UIScreen mainScreen].bounds;
    [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleBlackTranslucent animated:NO];

    UIViewController *controller = [[UIViewController alloc] init];
    controller.wantsFullScreenLayout = YES;
    controller.view = [[UIView alloc] initWithFrame:bounds];
    controller.view.backgroundColor = [UIColor blackColor];

    _canvasView = [[FMCanvasView alloc] initWithFrame:bounds];
    __weak FMInterface *weakSelf = self;
    _canvasView.showingHandler = ^(BOOL showing) {
        [weakSelf canvasDidShow:showing];
    };
    [controller.view addSubview:_canvasView];

    _glView = [[FMGLView alloc] initWithFrame:bounds];
    [controller.view addSubview:_glView];

    UIWindow *window = [[UIWindow alloc] initWithFrame:bounds];
    window.backgroundColor = [UIColor blackColor];
    window.rootViewController = controller;
    [self appDelegate].window = window;
    [window makeKeyAndVisible];

    if (![_glView start]) return;

    _volumeController = [MPMusicPlayerController applicationMusicPlayer];
    [_volumeController beginGeneratingPlaybackNotifications];
    [self volumeDidChange:nil];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(playerStateDidChange:) name:FMPlayerStateDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(libraryDidChange:) name:FMSpotifyLibraryDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(volumeDidChange:) name:MPMusicPlayerControllerVolumeDidChangeNotification object:_volumeController];
    for (NSString *name in @[FMWebAPIDidLogInNotification, FMWebAPIDidLogOutNotification, FMLibrespotDidLogInNotification]) {
        [center addObserver:self selector:@selector(loginDidChange:) name:name object:nil];
    }
    [center addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];

    _progressTimer = [NSTimer timerWithTimeInterval:0.25 target:self selector:@selector(updateProgress) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_progressTimer forMode:NSRunLoopCommonModes];

    [self sendGreeting];
    [self updateNowPlaying];
    [self logInOrShowScreens];
}

#pragma mark - Logging in

// Both logins happen on another device, these notifications say when they're done.
- (void)loginDidChange:(NSNotification *)notification
{
    [self logInOrShowScreens];
}

- (void)logInOrShowScreens
{
    FMSpotifyClient *client = [self client];
    if (client.isLoggedIn) {
        [self showMainScreens];
        return;
    }
    if (!client.token.refreshToken) {
        [self showLoginPage];
        return;
    }

    [self send:@"session" :@{@"screen": @"loading"}];
    // Connects to Spotify, keep that off the main thread.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error;
        BOOL isLoggedIn = [client refreshTokenWithError:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) [[self appDelegate] displayError:error];
            if (isLoggedIn && !error) [self showMainScreens];
            else [self showLoginPage];
        });
    });
}

- (void)showMainScreens
{
    [[self appDelegate] stopWebAPILogin];
    [self send:@"session" :@{@"screen": @"main"}];
    [self loadPlaylists];
}

// A page Retrofy serves on the Wi-Fi takes the Web API login, with the user's own client ID. Playback needs picking
// Retrofy as a Spotify Connect device, the app delegate explains that once the page is done.
- (void)showLoginPage
{
    NSError *error;
    NSString *address = [[self appDelegate] startWebAPILoginWithError:&error];
    if (!address) [[self appDelegate] displayError:error];
    else if (![[self appDelegate] librespotHasLogin]) {
        NSError *discoveryError;
        if (![[self appDelegate] startLibrespotDiscoveryWithError:&discoveryError]) [[self appDelegate] displayError:discoveryError];
    }
    [self send:@"session" :@{@"screen": @"login", @"address": address ?: @"", @"status": error.localizedDescription ?: @""}];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    [self sendGreeting];
    if (_lastLoad && [_lastLoad timeIntervalSinceNow] < -FMInterfaceRefreshInterval) [self loadPlaylists];
}

#pragma mark - Home and Your Library

- (NSString *)greeting
{
    NSInteger hour = [[[NSCalendar currentCalendar] components:NSHourCalendarUnit fromDate:[NSDate date]] hour];
    return hour >= 5 && hour < 12 ? @"Good morning" : hour >= 12 && hour < 18 ? @"Good afternoon" : @"Good evening";
}

- (void)sendGreeting
{
    [self sendHome:nil];
}

- (FMSpotifyPlaylist *)likedSongs
{
    return _likedSongs ?: (_likedSongs = [FMSpotifyContent likedSongsPlaylist]);
}

- (void)loadPlaylists
{
    if (_isLoading || !self.client.token.refreshToken) return;
    _isLoading = YES;
    // Your Library through librespot has Spotify's own playlists, the Web API has the covers of the user's.
    [self.client getUserPlaylistsAndWhenSuccess:^(FMSpotifyPlaylistArray *playlists) {
        [self loadMoreWebPlaylists:playlists];
    } whenError:^(NSError *error) {
        [self loadLibraryWithWebPlaylists:nil];
    }];
}

- (void)loadMoreWebPlaylists:(FMSpotifyPlaylistArray *)playlists
{
    if ([playlists isComplete] || ![playlists hasNext]) {
        [self loadLibraryWithWebPlaylists:playlists];
        return;
    }
    [self.client continueArray:playlists withOnSuccess:^(FMSpotifyContinuableArray *page) {
        [self loadMoreWebPlaylists:playlists];
    } onError:^(NSError *error) {
        [self loadLibraryWithWebPlaylists:playlists];
    }];
}

- (void)loadLibraryWithWebPlaylists:(FMSpotifyPlaylistArray *)webPlaylists
{
    if (webPlaylists) _webPlaylists = webPlaylists;
    void (^finish)(NSArray *) = ^(NSArray *playlists) {
        _isLoading = NO;
        if (!playlists) return;
        _lastLoad = [NSDate date];
        [self showPlaylists:playlists];
    };

    if (![[self appDelegate] librespotHasLogin]) {
        finish(webPlaylists.items);
        return;
    }
    [FMSpotifyContent loadLibraryPlaylists:^(NSArray *playlists, NSError *error) {
        if (!playlists) {
            finish(webPlaylists.items);
            return;
        }
        for (FMSpotifyPlaylist *playlist in playlists) {
            if (playlist.imageURL) continue;
            NSUInteger index = [webPlaylists.items indexOfObject:playlist];
            if (index != NSNotFound) playlist.imageURL = [[webPlaylists.items objectAtIndex:index] imageURL];
        }
        finish(playlists);
    }];
}

- (NSDictionary *)tileForPlaylist:(FMSpotifyPlaylist *)playlist
{
    NSString *key = playlist.identifier ?: @"";
    [_playlists setObject:playlist forKey:key];
    NSString *cover = [playlist.imageURL absoluteString];
    if (cover) [self requestCover:playlist.imageURL];
    return @{@"key": key, @"name": playlist.name ?: @"", @"subtitle": playlist.description.length ? playlist.description : @"Playlist", @"cover": cover ?: @""};
}

- (NSArray *)tilesForPlaylists:(NSArray *)playlists
{
    NSMutableArray *tiles = [NSMutableArray arrayWithCapacity:playlists.count];
    for (FMSpotifyPlaylist *playlist in playlists) [tiles addObject:[self tileForPlaylist:playlist]];
    return tiles;
}

- (void)showPlaylists:(NSArray *)playlists
{
    [self sendHome:[self shelvesFromPlaylists:playlists]];
    NSMutableArray *tiles = [NSMutableArray arrayWithObject:@{@"key": @"liked", @"name": @"Liked Songs", @"subtitle": @"Playlist", @"cover": @""}];
    [tiles addObjectsFromArray:[self tilesForPlaylists:playlists]];
    [self send:@"library" :@{@"items": tiles}];
}

- (void)sendHome:(NSArray *)shelves
{
    static NSArray *lastShelves;
    if (shelves) lastShelves = shelves;
    [self send:@"home" :@{@"greeting": [self greeting], @"shelves": lastShelves ?: @[]}];
}

- (NSArray *)shelvesFromPlaylists:(NSArray *)playlists
{
    NSMutableArray *dailyMixes = [NSMutableArray array];
    NSMutableArray *madeForYou = [NSMutableArray array];
    NSMutableArray *topSongs = [NSMutableArray array];
    NSMutableArray *mixes = [NSMutableArray array];
    NSMutableArray *yours = [NSMutableArray array];
    NSArray *madeForYouNames = @[@"Discover Weekly", @"Release Radar", @"On Repeat", @"Repeat Rewind", @"daylist"];

    for (FMSpotifyPlaylist *playlist in playlists) {
        NSString *name = playlist.name ?: @"";
        if (!playlist.isSpotifyMade) [yours addObject:playlist];
        else if ([name hasPrefix:@"Daily Mix"]) [dailyMixes addObject:playlist];
        else if ([madeForYouNames containsObject:name]) [madeForYou addObject:playlist];
        else if ([name hasPrefix:@"Your Top Songs"] || [name isEqualToString:@"Your All-Time Top Songs"]) [topSongs addObject:playlist];
        else if ([name hasSuffix:@"Mix"] || [name hasSuffix:@"Radio"] || [name rangeOfString:@" + "].location != NSNotFound) [mixes addObject:playlist];
    }

    NSComparator byName = ^NSComparisonResult(FMSpotifyPlaylist *first, FMSpotifyPlaylist *second) {
        return [first.name compare:second.name options:NSNumericSearch];
    };
    [dailyMixes sortUsingComparator:byName];
    [topSongs sortUsingComparator:^NSComparisonResult(id first, id second) {
        return byName(second, first);
    }];
    [dailyMixes addObjectsFromArray:madeForYou];

    NSMutableArray *shelves = [NSMutableArray array];
    NSArray *titled = @[@[@"Made For You", dailyMixes], @[@"Your Top Songs", topSongs], @[@"Your mixes", mixes], @[@"Your playlists", yours]];
    for (NSArray *shelf in titled) {
        NSArray *items = [shelf objectAtIndex:1];
        if (items.count) [shelves addObject:@{@"title": [shelf objectAtIndex:0], @"items": [self tilesForPlaylists:items]}];
    }
    return shelves;
}

#pragma mark - Pictures

- (void)requestCover:(NSURL *)url
{
    if ([_requestedCovers containsObject:url]) return;
    [_requestedCovers addObject:url];
    [_coverQueue addObject:url];
    [self loadNextCovers];
}

// A library can have hundreds, a few at a time.
- (void)loadNextCovers
{
    while (_coverLoads < FMInterfaceMaximumCoverLoads && _coverQueue.count) {
        NSURL *url = [_coverQueue objectAtIndex:0];
        [_coverQueue removeObjectAtIndex:0];
        _coverLoads++;
        [self.client getDataFromURL:url withCallback:^(NSData *data) {
            UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                _coverLoads--;
                if (image) [self sendImage:image key:[url absoluteString] size:FMInterfaceThumbnailSize averageColor:NULL];
                else [_requestedCovers removeObject:url];
                [self loadNextCovers];
            });
        }];
    }
}

// Square, cropped like image-fit: cover, and opaque.
- (void)sendImage:(UIImage *)image key:(NSString *)key size:(CGFloat)size averageColor:(uint8_t *)averageColor
{
    size_t side = (size_t)size;
    NSMutableData *pixels = [NSMutableData dataWithLength:side * side * 4];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, side, side, 8, side * 4, colorSpace, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);
    if (!context) return;

    CGSize imageSize = image.size;
    CGFloat scale = MAX(size / MAX(imageSize.width, 1), size / MAX(imageSize.height, 1));
    CGRect rect = CGRectMake((size - imageSize.width * scale) / 2, (size - imageSize.height * scale) / 2, imageSize.width * scale, imageSize.height * scale);
    CGContextSetRGBFillColor(context, 0, 0, 0, 1);
    CGContextFillRect(context, CGRectMake(0, 0, size, size));
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, rect, image.CGImage);
    CGContextRelease(context);

    if (averageColor) {
        const uint8_t *bytes = pixels.bytes;
        unsigned long long totals[3] = {0, 0, 0};
        for (size_t index = 0; index < side * side; index++) {
            for (int channel = 0; channel < 3; channel++) totals[channel] += bytes[index * 4 + channel];
        }
        for (int channel = 0; channel < 3; channel++) averageColor[channel] = (uint8_t)(totals[channel] / (side * side));
    }
    fm_ui_image([key UTF8String], pixels.bytes, (uint32_t)side, (uint32_t)side);
}

#pragma mark - Track lists

- (NSString *)subtitleForTrack:(FMSpotifyTrack *)track
{
    int seconds = (int)round(track.duration);
    NSString *duration = [NSString stringWithFormat:@"%d:%02d", seconds / 60, seconds % 60];
    NSString *artist = track.artistName ?: track.album.name;
    return artist ? [NSString stringWithFormat:@"%@ · %@", artist, duration] : duration;
}

- (NSNumber *)savedValueForTrack:(FMSpotifyTrack *)track
{
    if (!track.identifier) return @(-1);
    NSNumber *saved = [[FMSpotifyLibrary sharedLibrary] isTrackSaved:track];
    return saved ? @([saved boolValue] ? 1 : 0) : @(-1);
}

- (NSDictionary *)rowForTrack:(FMSpotifyTrack *)track
{
    return @{@"id": track.identifier ?: @"", @"title": track.name ?: @"", @"subtitle": [self subtitleForTrack:track], @"saved": [self savedValueForTrack:track]};
}

- (BOOL)isLikedSongs:(FMSpotifyPlaylist *)playlist
{
    return [playlist.identifier isEqualToString:@"liked-songs"];
}

- (void)openPlaylist:(FMSpotifyPlaylist *)playlist
{
    _openPlaylist = playlist;
    _sentTracks = 0;
    _visibleTrack = 0;
    [self send:@"tracks" :@{@"reset": @YES, @"title": playlist.name ?: @"", @"items": @[], @"loading": @YES}];
    [self sendNewTracksLoading:YES];
    [self loadTracks:playlist.tracks];
}

- (void)sendNewTracksLoading:(BOOL)loading
{
    FMSpotifyTrackArray *tracks = _openPlaylist.tracks;
    NSMutableArray *rows = [NSMutableArray array];
    for (NSUInteger index = _sentTracks; index < tracks.count; index++) {
        FMSpotifyTrack *track = [tracks itemAtIndex:index];
        if (!track) continue;
        [rows addObject:[self rowForTrack:track]];
    }
    // Everything in Liked Songs is liked, no need to ask.
    if ([self isLikedSongs:_openPlaylist]) {
        NSRange newTracks = NSMakeRange(_sentTracks, tracks.count - _sentTracks);
        [[FMSpotifyLibrary sharedLibrary] rememberTracks:[tracks.items subarrayWithRange:newTracks] saved:YES];
    }
    _sentTracks = tracks.count;
    [self send:@"tracks" :@{@"items": rows, @"loading": @(loading)}];
    [self requestVisibleSavedState];
}

- (void)loadTracks:(FMSpotifyTrackArray *)tracks
{
    FMSpotifyPlaylist *playlist = _openPlaylist;
    if (!tracks) return;
    if ([_librespotLoadingPlaylists containsObject:playlist.identifier ?: @""]) return;
    // Playlists are paged (100 tracks per page), keep loading until every page is there.
    if (tracks.count > 0 && ![tracks hasNext]) {
        [self sendNewTracksLoading:NO];
        return;
    }

    // Playlists from Your Library have no Web API address, and it refuses Spotify's own ones anyway.
    if ((playlist.isSpotifyMade || !tracks.href) && tracks == playlist.tracks && [[self appDelegate] librespotAvailable]) {
        [self loadTracksWithLibrespot:playlist offset:tracks.count];
        return;
    }
    [self.client continueArray:tracks withOnSuccess:^(FMSpotifyContinuableArray *newTracks) {
        if (tracks != _openPlaylist.tracks) return;
        BOOL hasMore = [newTracks hasNext];
        [self sendNewTracksLoading:hasMore];
        if (hasMore) [self loadTracks:tracks];
    } onError:^(NSError *error) {
        // Spotify only lets Retrofy's Web API client list the user's own playlists, librespot can list any.
        BOOL isPlaylist = playlist.identifier && playlist.tracks == tracks && ![self isLikedSongs:playlist];
        if (error.code == 403 && isPlaylist && [[self appDelegate] librespotAvailable]) {
            [self loadTracksWithLibrespot:playlist offset:tracks.count];
            return;
        }
        if (tracks == _openPlaylist.tracks) [self sendNewTracksLoading:NO];
        [[self appDelegate] displayError:error];
    }];
}

- (void)loadTracksWithLibrespot:(FMSpotifyPlaylist *)playlist offset:(NSUInteger)offset
{
    [_librespotLoadingPlaylists addObject:playlist.identifier];
    [[self appDelegate] loadPlaylistTracksWithLibrespot:playlist.identifier offset:offset limit:FMInterfacePlaylistPageSize completion:^(NSDictionary *page, NSError *error) {
        NSNumber *nextOffset = [page objectForKey:@"next_offset"];
        BOOL hasMore = !error && [nextOffset isKindOfClass:[NSNumber class]];
        if (page) [playlist.tracks addItemsFromDictionary:page];
        if (playlist == _openPlaylist) [self sendNewTracksLoading:hasMore];

        if (hasMore) {
            // Keeps loading after leaving the playlist, so the playlist is complete when it's opened again.
            [self loadTracksWithLibrespot:playlist offset:[nextOffset unsignedIntegerValue]];
            return;
        }
        [_librespotLoadingPlaylists removeObject:playlist.identifier];
        if (error) [[self appDelegate] displayError:error];
    }];
}

- (void)requestVisibleSavedState
{
    FMSpotifyTrackArray *tracks = _openPlaylist.tracks;
    if (_visibleTrack >= tracks.count) return;
    NSRange range = NSMakeRange(_visibleTrack, MIN(FMInterfaceVisibleRows, tracks.count - _visibleTrack));
    [[FMSpotifyLibrary sharedLibrary] requestSavedStateForTracks:[tracks.items subarrayWithRange:range]];
}

- (void)sendSavedStateForList:(NSString *)list tracks:(FMSpotifyTrackArray *)tracks from:(NSUInteger)from count:(NSUInteger)count
{
    NSMutableArray *saved = [NSMutableArray array];
    for (NSUInteger index = from; index < MIN(from + count, tracks.count); index++) {
        [saved addObject:[self savedValueForTrack:[tracks itemAtIndex:index]]];
    }
    if (saved.count) [self send:@"saved" :@{@"list": list, @"from": @(from), @"saved": saved}];
}

- (void)libraryDidChange:(NSNotification *)notification
{
    // Liked Songs loads again with the change next time it's opened.
    _likedSongs = nil;
    [self sendSavedStateForList:@"tracks" tracks:_openPlaylist.tracks from:_visibleTrack count:FMInterfaceVisibleRows];
    [self sendSavedStateForList:@"search" tracks:_searchResults from:0 count:_searchResults.count];
    [self updateNowPlaying];
}

#pragma mark - Search

- (void)viewTouched
{
    [_searchField resignFirstResponder];
}

- (void)beginSearch:(NSString *)text
{
    if (!_searchField) {
        CGFloat width = _glView.bounds.size.width;
        _searchField = [[UITextField alloc] initWithFrame:CGRectMake(FMInterfaceSearchFieldX, FMInterfaceSearchFieldY, width - FMInterfaceSearchFieldX - 28, FMInterfaceSearchFieldHeight)];
        _searchField.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
        _searchField.textColor = [UIColor whiteColor];
        _searchField.font = [UIFont systemFontOfSize:15];
        _searchField.placeholder = @"Songs and artists";
        _searchField.keyboardAppearance = UIKeyboardAppearanceAlert;
        _searchField.returnKeyType = UIReturnKeySearch;
        _searchField.autocorrectionType = UITextAutocorrectionTypeNo;
        _searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
        _searchField.delegate = self;
        [_glView.superview addSubview:_searchField];
    }
    _searchField.hidden = NO;
    [self send:@"search-field" :@{@"text": _searchField.text ?: @"", @"editing": @YES}];
    [_searchField becomeFirstResponder];
}

- (void)textFieldDidEndEditing:(UITextField *)textField
{
    textField.hidden = YES;
    [self send:@"search-field" :@{@"text": textField.text ?: @"", @"editing": @NO}];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    NSString *query = textField.text;
    if (!query.length) return NO;

    [self send:@"search" :@{@"items": @[], @"status": @"Searching"}];
    [self.client search:query withOnSuccess:^(FMSpotifyTrackArray *tracks) {
        _searchResults = tracks;
        NSMutableArray *rows = [NSMutableArray array];
        for (NSUInteger index = 0; index < tracks.count; index++) [rows addObject:[self rowForTrack:[tracks itemAtIndex:index]]];
        [self send:@"search" :@{@"items": rows, @"status": rows.count ? @"" : @"Nothing found"}];
        [[FMSpotifyLibrary sharedLibrary] requestSavedStateForTracks:tracks.items];
    } onError:^(NSError *error) {
        [self send:@"search" :@{@"items": @[], @"status": @""}];
        [[self appDelegate] displayError:error];
    }];
    return NO;
}

#pragma mark - Liked Songs

- (void)likeTapped:(FMSpotifyTrack *)track
{
    if (!track.identifier) return;
    _actionTrack = track;
    FMSpotifyLibrary *library = [FMSpotifyLibrary sharedLibrary];
    if ([[library isTrackSaved:track] boolValue]) {
        [self send:@"sheet" :@{@"title": track.name ?: @""}];
        return;
    }
    [library setTrack:track saved:YES completion:^(NSError *error) {
        if (error) [self showLibraryError:error];
        else [self showToast:@"Added to Liked Songs"];
    }];
}

- (void)removeActionTrack
{
    [[FMSpotifyLibrary sharedLibrary] setTrack:_actionTrack saved:NO completion:^(NSError *error) {
        if (error) [self showLibraryError:error];
        else [self showToast:@"Removed from Liked Songs"];
    }];
}

- (void)showPlaylistPicker
{
    _pickerPlaylists = [_webPlaylists.items copy];
    [self send:@"picker" :@{@"items": [self tilesForPlaylists:_pickerPlaylists], @"open": @YES}];
}

- (void)addActionTrackToPlaylistAtIndex:(int)index
{
    if (index < 0 || index >= (int)_pickerPlaylists.count) return;
    FMSpotifyPlaylist *playlist = [_pickerPlaylists objectAtIndex:index];
    [[FMSpotifyLibrary sharedLibrary] addTrack:_actionTrack toPlaylist:playlist completion:^(NSError *error) {
        if (error) [self showLibraryError:error];
        else [self showToast:[NSString stringWithFormat:@"Added to %@", playlist.name ?: @"playlist"]];
    }];
}

- (void)showToast:(NSString *)message
{
    [self send:@"toast" :@{@"text": message}];
}

- (void)showLibraryError:(NSError *)error
{
    if (error.code == FMSpotifyLibraryNeedsLoginErrorCode) {
        [[[UIAlertView alloc] initWithTitle:error.localizedFailureReason message:error.localizedDescription delegate:self cancelButtonTitle:@"Not Now" otherButtonTitles:@"Log In Again", nil] show];
        return;
    }
    [[self appDelegate] displayError:error];
}

// Posts FMWebAPIDidLogOutNotification, which shows the login page.
- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex != alertView.cancelButtonIndex) [[FMSpotifyLibrary sharedLibrary] logOutOfWebAPI];
}

#pragma mark - Now Playing

- (void)playerStateDidChange:(NSNotification *)notification
{
    [self updateNowPlaying];
}

- (void)volumeDidChange:(NSNotification *)notification
{
    [self send:@"volume" :@{@"volume": @(_volumeController.volume)}];
}

- (void)updateNowPlaying
{
    FMPlayer *player = [FMPlayer sharedPlayer];
    FMSpotifyTrack *track = player.currentTrack;

    if (player.coverImage != _sentCover) {
        _sentCover = player.coverImage;
        _tint = nil;
        if (_sentCover) {
            uint8_t color[3];
            [self sendImage:_sentCover key:@"now" size:FMInterfaceCoverSize averageColor:color];
            _tint = [NSString stringWithFormat:@"#%02x%02x%02x", color[0], color[1], color[2]];
        }
    }

    NSNumber *saved = [[FMSpotifyLibrary sharedLibrary] isTrackSaved:track];
    if (!saved && track && ![track isEqual:_checkedTrack]) {
        _checkedTrack = track;
        [[FMSpotifyLibrary sharedLibrary] checkTrackSaved:track completion:^(BOOL isSaved, NSError *error) {
            [self updateNowPlaying];
        }];
    }

    [self lookUpLyricsAndCanvasForTrack:track];
    _canvasView.playing = player.isPlaying && _nowPlayingOpen;

    NSString *subtitle = track.artistName ?: track.album.name ?: player.contextName;
    if (player.isPreview) subtitle = [NSString stringWithFormat:@"Preview · %@", subtitle ?: @""];
    [self send:@"now" :@{
        @"id": track.identifier ?: @"",
        @"title": track.name ?: @"",
        @"subtitle": subtitle ?: @"",
        @"context": player.contextName ?: @"",
        @"commentary": [[FMDJSession sharedSession] commentaryForTrack:track] ?: @"",
        @"playing": @(player.isPlaying),
        @"loading": @(player.isLoading),
        @"shuffle": @(player.shuffle),
        @"repeat": @(player.repeatMode),
        @"saved": [self savedValueForTrack:track],
        @"has_lyrics": @(_hasLyrics),
        @"has_video": @(_hasVideo),
        // A comparison is an int, which JSON would send as 1, not true.
        @"has_cover": _sentCover ? @YES : @NO,
        @"tint": _tint ?: @"",
    }];
    [self updateProgress];
}

- (void)lookUpLyricsAndCanvasForTrack:(FMSpotifyTrack *)track
{
    if (track == _lookedUpTrack || [track isEqual:_lookedUpTrack]) return;
    _lookedUpTrack = track;
    _hasLyrics = NO;
    _hasVideo = NO;
    _lyricStartTimes = nil;
    [_canvasView showVideoAtURL:nil];
    [self send:@"lyrics" :@{@"lines": @[@"No lyrics for this track"]}];
    if (!track) return;

    [FMSpotifyContent loadCanvasForTrack:track completion:^(NSURL *fileURL) {
        if (track != _lookedUpTrack) return;
        [_canvasView showVideoAtURL:fileURL];
        _canvasView.playing = [[FMPlayer sharedPlayer] isPlaying] && _nowPlayingOpen;
    }];
    [FMSpotifyContent loadLyricsForTrack:track completion:^(NSDictionary *response) {
        if (track != _lookedUpTrack) return;
        [self showLyrics:response];
        [self updateNowPlaying];
    }];
}

// The cover stays until a clip really shows.
- (void)canvasDidShow:(BOOL)showing
{
    _hasVideo = showing;
    [self updateNowPlaying];
}

// Spotify sends colors as signed 32-bit ARGB.
- (NSString *)colorFromValue:(id)value
{
    if (![value isKindOfClass:[NSNumber class]]) return @"";
    uint32_t argb = (uint32_t)[value longLongValue];
    return [NSString stringWithFormat:@"#%06x", argb & 0xFFFFFF];
}

- (void)showLyrics:(NSDictionary *)response
{
    NSDictionary *lyrics = [response objectForKey:@"lyrics"];
    NSArray *lines = [lyrics isKindOfClass:[NSDictionary class]] ? [lyrics objectForKey:@"lines"] : nil;
    NSMutableArray *words = [NSMutableArray array];
    NSMutableArray *startTimes = [NSMutableArray array];
    if ([lines isKindOfClass:[NSArray class]]) for (NSDictionary *line in lines) {
        if (![line isKindOfClass:[NSDictionary class]]) continue;
        NSString *lineWords = [line objectForKey:@"words"];
        if (![lineWords isKindOfClass:[NSString class]]) continue;
        [words addObject:lineWords.length ? lineWords : @"♪"];
        // A string in Spotify's JSON.
        [startTimes addObject:@([[line objectForKey:@"startTimeMs"] doubleValue] / 1000)];
    }

    _hasLyrics = words.count > 0;
    _lyricStartTimes = startTimes;
    _lyricsSynced = [[lyrics objectForKey:@"syncType"] isEqual:@"LINE_SYNCED"];
    NSDictionary *colors = [response objectForKey:@"colors"];
    if (![colors isKindOfClass:[NSDictionary class]]) colors = nil;
    [self send:@"lyrics" :@{
        @"lines": words.count ? words : @[@"No lyrics for this track"],
        @"synced": @(_lyricsSynced),
        @"background": [self colorFromValue:[colors objectForKey:@"background"]],
        @"text": [self colorFromValue:[colors objectForKey:@"text"]],
        @"highlight": [self colorFromValue:[colors objectForKey:@"highlightText"]],
    }];
}

- (void)updateProgress
{
    FMPlayer *player = [FMPlayer sharedPlayer];
    NSTimeInterval position = player.position;
    int line = -1;
    if (_lyricsSynced) {
        for (NSUInteger index = 0; index < _lyricStartTimes.count; index++) {
            if ([[_lyricStartTimes objectAtIndex:index] doubleValue] > position + FMInterfaceLyricsLeadTime) break;
            line = (int)index;
        }
    }
    fm_ui_progress(position, player.duration, line);
}

#pragma mark - What the user did

- (void)open:(NSString *)key
{
    if ([key isEqualToString:@"dj"]) {
        [[FMDJSession sharedSession] start];
        [self send:@"open-now" :@{}];
        return;
    }
    FMSpotifyPlaylist *playlist = [key isEqualToString:@"liked"] ? [self likedSongs] : [_playlists objectForKey:key];
    if (playlist) [self openPlaylist:playlist];
}

- (void)playTrackAtIndex:(int)index inList:(NSString *)list
{
    if ([list isEqualToString:@"search"]) {
        [[FMPlayer sharedPlayer] playTracks:_searchResults startingAtIndex:index contextName:@"Search" contextURI:nil];
    } else {
        NSString *contextURI = [self isLikedSongs:_openPlaylist] ? @"spotify:collection" : [@"spotify:playlist:" stringByAppendingString:_openPlaylist.identifier];
        [[FMPlayer sharedPlayer] playTracks:_openPlaylist.tracks startingAtIndex:index contextName:_openPlaylist.name contextURI:contextURI];
    }
    [self send:@"open-now" :@{}];
}

- (void)handleAction:(NSString *)name index:(int)index text:(NSString *)text
{
    FMPlayer *player = [FMPlayer sharedPlayer];
    if ([name isEqualToString:@"open"]) [self open:text];
    else if ([name isEqualToString:@"play-track"]) [self playTrackAtIndex:index inList:text];
    else if ([name isEqualToString:@"like-track"]) {
        FMSpotifyTrackArray *tracks = [text isEqualToString:@"search"] ? _searchResults : _openPlaylist.tracks;
        [self likeTapped:[tracks itemAtIndex:index]];
    }
    else if ([name isEqualToString:@"like-now"]) [self likeTapped:player.currentTrack];
    else if ([name isEqualToString:@"tracks-visible"]) {
        _visibleTrack = index;
        [self requestVisibleSavedState];
        [self sendSavedStateForList:@"tracks" tracks:_openPlaylist.tracks from:_visibleTrack count:FMInterfaceVisibleRows];
    }
    else if ([name isEqualToString:@"search-focus"]) [self beginSearch:text];
    else if ([name isEqualToString:@"sheet-add"]) [self showPlaylistPicker];
    else if ([name isEqualToString:@"sheet-remove"]) [self removeActionTrack];
    else if ([name isEqualToString:@"pick-playlist"]) [self addActionTrackToPlaylistAtIndex:index];
    else if ([name isEqualToString:@"toggle"]) [player togglePlayPause];
    else if ([name isEqualToString:@"next"]) [player next];
    else if ([name isEqualToString:@"previous"]) [player previous];
    else if ([name isEqualToString:@"shuffle"]) player.shuffle = !player.shuffle;
    // Off, all, one, like Spotify.
    else if ([name isEqualToString:@"repeat"]) player.repeatMode = (player.repeatMode + 1) % 3;
    else if ([name isEqualToString:@"seek"]) [player seekToPosition:index / 1000.0];
    else if ([name isEqualToString:@"volume"]) _volumeController.volume = index / 1000.0;
    else if ([name isEqualToString:@"lyric-seek"]) {
        if (_lyricsSynced && index < (int)_lyricStartTimes.count) [player seekToPosition:[[_lyricStartTimes objectAtIndex:index] doubleValue]];
    }
    else if ([name isEqualToString:@"now-open"]) {
        _nowPlayingOpen = index != 0;
        _canvasView.playing = player.isPlaying && _nowPlayingOpen;
    }
    else if ([name isEqualToString:@"retry-login"]) [self logInOrShowScreens];
    else NSLog(@"Interface: unknown action %@", name);
}

@end
