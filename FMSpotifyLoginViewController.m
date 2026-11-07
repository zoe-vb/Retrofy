//
//  FMSpotifyLoginViewController.m
//  Retrofy
//
//  Created by Lasse Lauwerys on 27/06/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import "FMSpotifyLoginViewController.h"
#import "FMAppDelegate.h"
#import "FMSecondViewController.h"
#import "FMTheme.h"

@implementation FMSpotifyLoginViewController

#ifdef FM_IOS4
// Comes from a storyboard on iOS 5 and later.
- (void)loadView
{
    UIView *view = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    CGFloat width = view.bounds.size.width;

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 40, width - 40, 44)];
    titleLabel.text = @"Retrofy";
    titleLabel.font = [UIFont systemFontOfSize:36];
    titleLabel.textAlignment = UITextAlignmentCenter;
    [view addSubview:titleLabel];

    UILabel *instructionLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 96, width - 40, 40)];
    instructionLabel.text = @"On a computer on the same Wi-Fi, open this address:";
    instructionLabel.font = [UIFont systemFontOfSize:15];
    instructionLabel.numberOfLines = 2;
    instructionLabel.textAlignment = UITextAlignmentCenter;
    [view addSubview:instructionLabel];

    UITextField *addressField = [[UITextField alloc] initWithFrame:CGRectMake(20, 146, width - 40, 34)];
    addressField.borderStyle = UITextBorderStyleRoundedRect;
    addressField.font = [UIFont systemFontOfSize:17];
    addressField.textAlignment = UITextAlignmentCenter;
    addressField.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    addressField.enabled = NO;
    [view addSubview:addressField];
    self.userCodeField = addressField;

    UIButton *refreshButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    refreshButton.frame = CGRectMake(20, 196, width - 40, 40);
    [refreshButton setTitle:@"Try Again" forState:UIControlStateNormal];
    [refreshButton addTarget:self action:@selector(refreshCode:) forControlEvents:UIControlEventTouchUpInside];
    [view addSubview:refreshButton];

    self.view = view;
}
#endif
- (void)viewDidLoad
{
    [super viewDidLoad];
    [FMTheme styleView:self.view];
    
//    FMWaveForm *waveForm = [[FMWaveForm alloc] init];
//    [waveForm renderPNGAudioPictogramForAsset:<#(AVURLAsset *)#>]
    
    [self getNewUserCode];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    // The timer retains this controller and would keep requesting new codes after logging in.
    [activeTimer invalidate];
    activeTimer = nil;
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (FMSpotifyClient *)spotifyClient
{
    return self.appDelegate.spotifyClient;
}

- (void)refreshCode:(id)sender
{
    [self getNewUserCode];
}

- (void)shareCode:(id)sender
{
#ifndef FM_IOS4
    if (shareURL) [self presentViewController:[[UIActivityViewController alloc] initWithActivityItems:@[shareURL] applicationActivities:nil] animated:YES completion:nil];
    else
#endif
    [[[UIAlertView alloc] initWithTitle:@"Error" message:@"The URL was not found." delegate:nil cancelButtonTitle:@"Shut up!" otherButtonTitles:nil, nil] show];
}

- (void)getNewUserCode
{
    if (activeTimer) [activeTimer invalidate];

#ifdef FM_LIBRESPOT
    // No pair code. Two logins, both done on another device on the same Wi-Fi:
    // - Web API (playlists, search): a page Retrofy serves, where the user also enters their own client ID.
    // - Playback: picking Retrofy as a Spotify Connect device, only until librespot has a saved login.
    // The page controller moves on once FMWebAPIDidLogInNotification arrives.
    [self setProgressIndeterminate:NO];
    [self.shareButton setEnabled:NO];
    [self.remainingTimeView setHidden:YES];

    NSError *loginError;
    NSString *loginAddress = [self.appDelegate startWebAPILoginWithError:&loginError];
    [self.userCodeField setText:loginAddress ? loginAddress : @""];
    if (!loginAddress) {
        [self.appDelegate displayError:loginError];
        return;
    }

    NSString *instructions = [NSString stringWithFormat:@"On a computer on the same Wi-Fi, open %@ and follow the steps.", loginAddress];
    if (![self.appDelegate librespotHasLogin]) {
        NSError *discoveryError;
        // The app delegate explains this step once the login on the page is done.
        if (![self.appDelegate startLibrespotDiscoveryWithError:&discoveryError]) [self.appDelegate displayError:discoveryError];
    }
    [[[UIAlertView alloc] initWithTitle:@"Log in to Spotify" message:instructions delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil, nil] show];
    return;
#endif

    [self setProgressIndeterminate:YES];
	
	NSError *error;
    
    FMSpotifyDeviceAuthorizationInfo *deviceAuthorizationInfo = [self.appDelegate.spotifyClient refreshDeviceAuthorizationInfoWithError:&error];
    if (error || !deviceAuthorizationInfo.userCode) {
        [self setProgressIndeterminate:NO];
        [self.userCodeField setText:@""];
        if (error) [self.appDelegate displayError:error];
	} else {
        expiresIn = [[deviceAuthorizationInfo expiresIn] doubleValue];
        if (expiresIn <= 0) expiresIn = 600;
        shareURL = deviceAuthorizationInfo.completeVerificationURL;
        [self.shareButton setEnabled:shareURL != nil];
        [self.remainingTimeView setProgress:1];
        [self setProgressIndeterminate:NO];
        [self.userCodeField setText:deviceAuthorizationInfo.userCode];
        
        NSLog(@"user code: %@", [deviceAuthorizationInfo userCode]);
        NSLog(@"url: %@", [deviceAuthorizationInfo verificationURL]);
        NSLog(@"expires in %lf", expiresIn);
        
        activeTimer = [NSTimer timerWithTimeInterval:1 target:self selector:@selector(updateRemainingTime) userInfo:nil repeats:YES];
        
        [[NSRunLoop currentRunLoop] addTimer:activeTimer forMode:NSRunLoopCommonModes];
    }
}

- (void)setProgressIndeterminate:(BOOL)indeterminate
{
    if (indeterminate) {
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
    } else {
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
    }
}

- (void)updateRemainingTime
{
    [self.remainingTimeView setProgress:self.remainingTimeView.progress - (1 / expiresIn)];
    if (self.remainingTimeView.progress <= 0) [self getNewUserCode];
}

@end
