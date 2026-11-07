//
//  main.m
//  Retrofy iOS 4 playback test
//
//  One screen, no storyboards: pair over Spotify Connect, then play a track and see if an armv6 device
//  can keep up. Manual retain/release so it builds with the old compilers that still target armv6.
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

#import "fmlibrespot.h"

// Any track will do, change it in the text field on the device.
static NSString *const FMTestDefaultURI = @"spotify:track:4cOdK2wGLETKBW3PvgPWqT";

@interface FMTestController : UIViewController <UITextFieldDelegate>
{
    UITextField *_uriField;
    UITextView *_logView;
    NSDate *_loadStarted;
}
- (void)log:(NSString *)message;
- (void)event:(int)event position:(uint32_t)positionMs detail:(NSString *)detail;
@end

static void FMTestEvent(void *context, int event, uint32_t positionMs, const char *detail)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    FMTestController *controller = (FMTestController *)context;
    NSString *detailString = detail ? [NSString stringWithUTF8String:detail] : @"";
    if (event == FM_LIBRESPOT_EVENT_LOG) {
        NSLog(@"librespot: %@", detailString);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [controller event:event position:positionMs detail:detailString];
        });
    }
    [pool drain];
}

@implementation FMTestController

- (void)loadView
{
    UIView *view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]] autorelease];
    view.backgroundColor = [UIColor blackColor];
    CGFloat width = view.bounds.size.width;

    _uriField = [[UITextField alloc] initWithFrame:CGRectMake(10, 10, width - 20, 31)];
    _uriField.borderStyle = UITextBorderStyleRoundedRect;
    _uriField.font = [UIFont systemFontOfSize:12];
    _uriField.text = FMTestDefaultURI;
    _uriField.autocorrectionType = UITextAutocorrectionTypeNo;
    _uriField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _uriField.returnKeyType = UIReturnKeyDone;
    _uriField.delegate = self;
    [view addSubview:_uriField];

    NSArray *titles = [NSArray arrayWithObjects:@"Pair", @"Play", @"Pause", @"Resume", nil];
    SEL actions[] = {@selector(pair:), @selector(play:), @selector(pause:), @selector(resume:)};
    CGFloat buttonWidth = (width - 20) / titles.count;
    for (NSUInteger index = 0; index < titles.count; index++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        button.frame = CGRectMake(10 + index * buttonWidth, 50, buttonWidth - 4, 40);
        [button setTitle:[titles objectAtIndex:index] forState:UIControlStateNormal];
        [button addTarget:self action:actions[index] forControlEvents:UIControlEventTouchUpInside];
        [view addSubview:button];
    }

    _logView = [[UITextView alloc] initWithFrame:CGRectMake(10, 100, width - 20, view.bounds.size.height - 110)];
    _logView.autoresizingMask = UIViewAutoresizingFlexibleHeight;
    _logView.editable = NO;
    _logView.backgroundColor = [UIColor blackColor];
    _logView.textColor = [UIColor greenColor];
    _logView.font = [UIFont fontWithName:@"Courier" size:12];
    [view addSubview:_logView];

    self.view = view;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    char *selfTest = fm_librespot_self_test();
    [self log:[NSString stringWithFormat:@"self test: %s", selfTest]];
    fm_librespot_free_string(selfTest);

    NSString *library = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString *cacheDirectory = [library stringByAppendingPathComponent:@"librespot"];
    char *error = NULL;
    if (fm_librespot_init([cacheDirectory fileSystemRepresentation], self, FMTestEvent, &error)) {
        [self log:fm_librespot_has_login() ? @"init ok, saved login found" : @"init ok, no login yet: tap Pair"];
    } else {
        [self log:[NSString stringWithFormat:@"init failed: %s", error]];
        fm_librespot_free_string(error);
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    return YES;
}

- (void)log:(NSString *)message
{
    NSLog(@"%@", message);
    _logView.text = [_logView.text stringByAppendingFormat:@"%@\n", message];
    [_logView scrollRangeToVisible:NSMakeRange(_logView.text.length, 0)];
}

- (void)pair:(id)sender
{
    char *error = NULL;
    if (fm_librespot_start_discovery("Retrofy Test", &error)) {
        [self log:@"Pick \"Retrofy Test\" in the Spotify app on the same Wi-Fi"];
    } else {
        [self log:[NSString stringWithFormat:@"discovery failed: %s", error]];
        fm_librespot_free_string(error);
    }
}

- (void)play:(id)sender
{
    NSString *uri = _uriField.text;
    [_loadStarted release];
    _loadStarted = [[NSDate date] retain];
    [self log:[NSString stringWithFormat:@"loading %@", uri]];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        char *error = NULL;
        BOOL loaded = fm_connect_play_context(NULL, [[NSString stringWithFormat:@"[\"%@\"]", uri] UTF8String], NULL, 0, false, 0, &error);
        NSString *message = !loaded && error ? [NSString stringWithUTF8String:error] : nil;
        fm_librespot_free_string(error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!loaded) [self log:[NSString stringWithFormat:@"load failed: %@", message]];
        });
    });
}

- (void)pause:(id)sender
{
    fm_librespot_pause();
}

- (void)resume:(id)sender
{
    fm_librespot_play();
}

- (void)event:(int)event position:(uint32_t)positionMs detail:(NSString *)detail
{
    switch (event) {
        case FM_LIBRESPOT_EVENT_PLAYING:
            [self log:[NSString stringWithFormat:@"playing at %u ms, %.1f s after tapping Play", positionMs, -[_loadStarted timeIntervalSinceNow]]];
            break;
        case FM_LIBRESPOT_EVENT_PAUSED:
            [self log:[NSString stringWithFormat:@"paused at %u ms", positionMs]];
            break;
        case FM_LIBRESPOT_EVENT_STOPPED:
            [self log:@"stopped"];
            break;
        case FM_LIBRESPOT_EVENT_END_OF_TRACK:
            [self log:@"end of track"];
            break;
        case FM_LIBRESPOT_EVENT_UNAVAILABLE:
            [self log:@"track unavailable"];
            break;
        case FM_LIBRESPOT_EVENT_LOADING:
            [self log:@"loading audio"];
            break;
        case FM_LIBRESPOT_EVENT_LOGGED_IN:
            fm_librespot_stop_discovery();
            [self log:[NSString stringWithFormat:@"logged in as %@", detail]];
            break;
        case FM_LIBRESPOT_EVENT_LOGIN_FAILED:
            [self log:[NSString stringWithFormat:@"login failed: %@", detail]];
            break;
        default:
            break;
    }
}

@end

@interface FMTestAppDelegate : NSObject <UIApplicationDelegate>
{
    UIWindow *_window;
}
@end

@implementation FMTestAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    // Playback dropouts are the point of this test, the screen dimming shouldn't add to them.
    application.idleTimerDisabled = YES;

    _window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    FMTestController *controller = [[[FMTestController alloc] init] autorelease];
    _window.rootViewController = controller;
    [_window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int result = UIApplicationMain(argc, argv, nil, @"FMTestAppDelegate");
    [pool drain];
    return result;
}
