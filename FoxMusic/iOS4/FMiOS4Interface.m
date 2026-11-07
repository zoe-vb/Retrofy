//
//  FMiOS4Interface.m
//  Retrofy
//
//  Builds in code what the storyboards set up on iOS 5 and later: the tabs, and switching between them
//  and the login screen. Storyboards need iOS 5.
//

#import "FMiOS4Interface.h"

#import "FMAppDelegate.h"
#import "FMSearchViewController.h"
#import "FMSpotifyLibrary.h"
#import "FMSpotifyLoginViewController.h"
#import "FMSpotifyPlaylistTableViewController.h"
#import "FMTheme.h"

@interface FMiOS4Interface ()
{
    UIWindow *_window;
}
@end

@implementation FMiOS4Interface

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (FMAppDelegate *)appDelegate
{
    return (FMAppDelegate *)[[UIApplication sharedApplication] delegate];
}

- (void)show
{
    _window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    _window.backgroundColor = [FMTheme backgroundColor];
    [self appDelegate].window = _window;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(loginDidChange:) name:FMWebAPIDidLogInNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(loginDidChange:) name:FMWebAPIDidLogOutNotification object:nil];

    UIViewController *loadingViewController = [[UIViewController alloc] init];
    loadingViewController.view.backgroundColor = [FMTheme backgroundColor];
    _window.rootViewController = loadingViewController;
    [_window makeKeyAndVisible];

    // Refreshing the token talks to Spotify, keep that off the main thread.
    FMSpotifyClient *client = [[self appDelegate] spotifyClient];
    if (client.isLoggedIn) {
        [self showTabs];
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL isLoggedIn = NO;
        @try {
            isLoggedIn = [client refreshTokenWithError:nil];
        }
        @catch (NSException *exception) {
            NSLog(@"Couldn't refresh the login: %@", exception.reason);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (isLoggedIn) [self showTabs];
            else [self showLogin];
        });
    });
}

- (void)loginDidChange:(NSNotification *)notification
{
    if ([[self appDelegate] spotifyClient].isLoggedIn) [self showTabs];
    else [self showLogin];
}

- (UINavigationController *)navigationControllerWithRoot:(UIViewController *)viewController
{
    UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:viewController];
    navigationController.navigationBar.tintColor = [UIColor colorWithWhite:0.16 alpha:1];
    return navigationController;
}

- (void)showTabs
{
    FMSpotifyPlaylistTableViewController *playlists = [[FMSpotifyPlaylistTableViewController alloc] initWithStyle:UITableViewStylePlain];
    playlists.title = @"Playlists";
    UINavigationController *playlistsTab = [self navigationControllerWithRoot:playlists];
    playlistsTab.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Playlists" image:[UIImage imageNamed:@"spotify.png"] tag:0];

    FMSearchViewController *search = [[FMSearchViewController alloc] init];
    search.title = @"Search";
    UINavigationController *searchTab = [self navigationControllerWithRoot:search];
    searchTab.tabBarItem = [[UITabBarItem alloc] initWithTabBarSystemItem:UITabBarSystemItemSearch tag:1];

    UITabBarController *tabBarController = [[UITabBarController alloc] init];
    tabBarController.viewControllers = [NSArray arrayWithObjects:playlistsTab, searchTab, nil];
    _window.rootViewController = tabBarController;
}

- (void)showLogin
{
    if ([_window.rootViewController isKindOfClass:[FMSpotifyLoginViewController class]]) return;
    _window.rootViewController = [[FMSpotifyLoginViewController alloc] init];
}

@end
