//
//  FMSpotifyLoginPageViewController.m
//  FoxMusic
//
//  Created by Lasse Lauwerys on 27/06/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import "FMSpotifyLoginPageViewController.h"

@implementation FMSpotifyLoginPageViewController
- (void)viewDidLoad
{
    [super viewDidLoad];
    hasShownLoginPage = NO;

    // Both logins happen on another device, the app delegate tells us when they're done.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(librespotDidLogIn:) name:FMLibrespotDidLogInNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(webAPIDidLogIn:) name:FMWebAPIDidLogInNotification object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    NSLog(@"the loading view appeared!");

    @try {
        FMSpotifyClient *spotifyClient = [self.appDelegate spotifyClient];

        // Coming back to this tab while logged in shouldn't reset the Spotify navigation stack.
        if ([currentIdentifier isEqualToString:@"spotify"] && spotifyClient.isLoggedIn) return;

        if (spotifyClient.isLoggedIn) {
            [self showPageForLogin:YES error:nil];
            return;
        }

#ifdef FM_LIBRESPOT
        // Restoring the saved Spotify Connect login connects to Spotify, keep that off the main thread.
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError *error;
            BOOL isLoggedIn = [spotifyClient refreshTokenWithError:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
                [self showPageForLogin:isLoggedIn error:error];
            });
        });
#else
        NSLog(@"Token expired, refreshing");
        NSError *error;
        BOOL isLoggedIn = [spotifyClient refreshTokenWithError:&error];
        [self showPageForLogin:isLoggedIn error:error];
#endif
    }
    @catch (NSException *exception) {
        [self.appDelegate displayException:exception];
    }
}

- (void)showPageForLogin:(BOOL)isLoggedIn error:(NSError *)error
{
    if (error) [self.appDelegate displayError:error];

    NSString *viewControllerIdentifier = !error && isLoggedIn ? @"spotify" : @"login";

    // Don't replace the page (and the login code on it) every time the tab appears.
    if ([currentIdentifier isEqualToString:viewControllerIdentifier]) return;
    [self navigateToControllerWithIdentifier:viewControllerIdentifier forwards:YES];
}

- (void)librespotDidLogIn:(NSNotification *)notification
{
    // Only playback depends on this login, the Spotify page waits for the Web API login.
    NSLog(@"Logged in through Spotify Connect as %@", notification.userInfo[@"username"]);
    if (self.appDelegate.spotifyClient.isLoggedIn) [self showPageForLogin:YES error:nil];
}

- (void)webAPIDidLogIn:(NSNotification *)notification
{
    [self showPageForLogin:self.appDelegate.spotifyClient.isLoggedIn error:nil];
}

- (void)logIn:(id)sender
{
    NSError *error;
    @try {
#ifdef FM_LIBRESPOT
        // The login itself arrives through librespotDidLogIn:, this only covers tapping Done early.
        if (!self.appDelegate.spotifyClient.isLoggedIn) {
            [[[UIAlertView alloc] initWithTitle:@"Not logged in yet" message:@"Open the address shown on this screen in a browser on a computer on the same Wi-Fi and finish the steps there." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil, nil] show];
            return;
        }
#else
        if (![self.appDelegate.spotifyClient tryDeviceAuhorizationWithError:&error] || error) [self.appDelegate displayError:error];
#endif
        NSLog(@"Logged in? %@", self.appDelegate.spotifyClient.isLoggedIn ? @"yes" : @"no");
        if (self.appDelegate.spotifyClient.isLoggedIn) [self navigateToControllerWithIdentifier:@"spotify" forwards:YES];

    }
    @catch (NSException *exception) {
        [self.appDelegate displayException:exception];
    }
}
- (void)navigateToControllerWithIdentifier:(NSString *)identifier forwards:(BOOL)forwards
{
    // Use the storyboard this controller came from so the iPad storyboard is used on iPad.
    UIStoryboard *storyboard = self.storyboard ? self.storyboard : [UIStoryboard storyboardWithName:@"MainStoryboard_iPhone" bundle:nil];
    currentIdentifier = identifier;
    if (storyboard) [self setViewControllers:@[[storyboard instantiateViewControllerWithIdentifier:identifier]] direction:forwards ? UIPageViewControllerNavigationDirectionForward : UIPageViewControllerNavigationDirectionReverse animated:YES completion:nil];
}

@end
