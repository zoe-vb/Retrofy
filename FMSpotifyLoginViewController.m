//
//  FMSpotifyLoginViewController.m
//  FoxMusic
//
//  Created by Lasse Lauwerys on 27/06/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import "FMSpotifyLoginViewController.h"
#import "FMAppDelegate.h"
#import "FMSecondViewController.h"

@implementation FMSpotifyLoginViewController
- (void)viewDidLoad
{
    [super viewDidLoad];
    
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
    if (shareURL) [self presentViewController:[[UIActivityViewController alloc] initWithActivityItems:@[shareURL] applicationActivities:nil] animated:YES completion:nil];
    else [[[UIAlertView alloc] initWithTitle:@"Error" message:@"The URL was not found." delegate:nil cancelButtonTitle:@"Shut up!" otherButtonTitles:nil, nil] show];
}

- (void)getNewUserCode
{
    if (activeTimer) [activeTimer invalidate];

#ifdef FM_LIBRESPOT
    // No pair code. Two logins, both done on another device on the same Wi-Fi:
    // - Web API (playlists, search): a page FoxMusic serves, for FMSpotifyClientID's own quota.
    // - Playback: picking FoxMusic as a Spotify Connect device, only until librespot has a saved login.
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
        if ([self.appDelegate startLibrespotDiscoveryWithError:&discoveryError]) {
            instructions = [instructions stringByAppendingString:@"\n\nFor playback, also open Spotify on another phone or computer, tap the devices button and pick FoxMusic."];
        } else {
            [self.appDelegate displayError:discoveryError];
        }
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
