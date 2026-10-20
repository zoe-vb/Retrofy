//
//  FMAppDelegate.h
//  Retrofy
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
// librespot playback events, userInfo event (FMLibrespotPlaybackEvent), position (milliseconds) and uri.
extern NSString *const FMLibrespotPlaybackEventNotification;

// Same values as FM_LIBRESPOT_EVENT_* in fmlibrespot.h.
typedef enum {
    FMLibrespotPlaybackEventPlaying = 1,
    FMLibrespotPlaybackEventPaused = 2,
    FMLibrespotPlaybackEventStopped = 3,
    FMLibrespotPlaybackEventEndOfTrack = 4,
    FMLibrespotPlaybackEventUnavailable = 5,
} FMLibrespotPlaybackEvent;

@interface FMAppDelegate : UIResponder <UIApplicationDelegate, SRWebSocketDelegate>
{
    FMSpotifyClient *_spotifyClient;
    FMLucidaClient *_lucidaClient;

    // Serial queue for blocking librespot calls, only used when built with FM_LIBRESPOT.
    dispatch_queue_t _librespotQueue;
    BOOL _librespotPlaying;
}

@property (strong, nonatomic) UIWindow *window;

@property (readonly) FMSpotifyClient *spotifyClient;
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
// Starts the track `position` seconds in.
- (void)playTrackWithLibrespot:(FMSpotifyTrack *)track position:(NSTimeInterval)position completion:(void(^)(NSError *error))completion;
// Announces Retrofy as a Spotify Connect device, picking it in the Spotify app on another device logs in.
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
- (void)librespotSeekToPosition:(NSTimeInterval)position;
// A page of a playlist's tracks through librespot, for playlists the Web API answers with 403. The page is
// shaped like a Web API playlist items page, with next_offset (NSNumber, or NSNull at the end). Calls back on the main queue.
- (void)loadPlaylistTracksWithLibrespot:(NSString *)playlistID offset:(NSUInteger)offset limit:(NSUInteger)limit completion:(void(^)(NSDictionary *page, NSError *error))completion;

@end
