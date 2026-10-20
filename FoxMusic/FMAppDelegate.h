//
//  FMAppDelegate.h
//  FoxMusic
//
//  Created by Lasse Lauwerys on 26/06/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>

#import "FMTouch.h"
#import "FMAlertDelegate.h"

#import "SRWebSocket.h"

extern NSString *const FMLibrespotDidLogInNotification;
extern NSString *const FMWebAPIDidLogInNotification;

@interface FMAppDelegate : UIResponder <UIApplicationDelegate, SRWebSocketDelegate>
{
    FMSpotifyClient *_spotifyClient;
    FMYouTubeClient *_youtubeClient;
    FMLucidaClient *_lucidaClient;

    // Serial queue for blocking librespot calls, only used when built with FM_LIBRESPOT.
    dispatch_queue_t _librespotQueue;
    BOOL _librespotPlaying;
}

@property (strong, nonatomic) UIWindow *window;

@property (readonly) FMSpotifyClient *spotifyClient;
@property (readonly) FMYouTubeClient *youtubeClient;
@property (readonly) FMLucidaClient *lucidaClient;
@property FMAlertDelegate *alertDelegate;

@property IBOutlet UITabBarController *mainTabBarController;

@property FMSpotifyPlaylist *selectedPlaylist;
@property FMSpotifyTrack *selectedTrack;

@property AVAudioPlayer *audioPlayer;

- (void)displayError:(NSError *)error;
- (void)displayError:(NSError *)error withCompletionHandler:(void(^)())completionHandler;
- (void)displayException:(NSException *)exception;

- (void)loadAudioFromData:(NSData *)audioData;

// Full track playback through librespot (Spotify Premium). Only available when built with FM_LIBRESPOT.
@property (readonly, nonatomic) BOOL librespotAvailable;
// YES while librespot, not audioPlayer, is the active player.
@property (readonly) BOOL librespotActive;

- (void)playTrackWithLibrespot:(FMSpotifyTrack *)track completion:(void(^)(NSError *error))completion;
// Announces FoxMusic as a Spotify Connect device, picking it in the Spotify app on another device logs in.
// Posts FMLibrespotDidLogInNotification (userInfo username) or shows the error.
- (BOOL)startLibrespotDiscoveryWithError:(NSError **)error;
- (void)stopLibrespotDiscovery;
// Whether librespot has a Spotify Connect login (playback works).
@property (readonly, nonatomic) BOOL librespotHasLogin;
// Serves the Web API login page (FMSpotifyClientID's own quota) on the Wi-Fi and returns its address,
// e.g. http://192.168.1.238:8080. Posts FMWebAPIDidLogInNotification once logged in.
- (NSString *)startWebAPILoginWithError:(NSError **)error;
- (void)stopWebAPILogin;
- (void)librespotPause;
- (void)librespotResume;
- (void)librespotRewind;

@end
