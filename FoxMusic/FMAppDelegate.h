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

#ifndef FM_IOS4
#import "SRWebSocket.h"
#endif

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
    FMLibrespotPlaybackEventLoading = 6,
    FMLibrespotPlaybackEventTrackChanged = 11,
    FMLibrespotPlaybackEventPosition = 12,
    FMLibrespotPlaybackEventShuffle = 13,
    FMLibrespotPlaybackEventRepeat = 14,
    FMLibrespotPlaybackEventVolume = 15,
    FMLibrespotPlaybackEventInactive = 16,
} FMLibrespotPlaybackEvent;

#ifdef FM_IOS4
@class FMiOS4Interface;
@interface FMAppDelegate : UIResponder <UIApplicationDelegate>
#else
@interface FMAppDelegate : UIResponder <UIApplicationDelegate, SRWebSocketDelegate>
#endif
{
    FMSpotifyClient *_spotifyClient;
#ifdef FM_IOS4
    // The screens, which come from storyboards on iOS 5 and later.
    FMiOS4Interface *_interface;
#else
    FMLucidaClient *_lucidaClient;
#endif

    // Serial queue for blocking librespot calls, only used when built with FM_LIBRESPOT.
    dispatch_queue_t _librespotQueue;
    BOOL _librespotPlaying;
    // The reminder to pair over Spotify Connect shows once per launch.
    BOOL _showedPlaybackReminder;
    // Connect skips unplayable tracks by itself, one alert covers a whole run of them.
    NSDate *_lastUnavailableAlert;
}

@property (strong, nonatomic) UIWindow *window;

@property (readonly) FMSpotifyClient *spotifyClient;
#ifndef FM_IOS4
@property (readonly) FMLucidaClient *lucidaClient;
#endif
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
// Plays on Retrofy's Spotify Connect device, so Spotify runs the queue, shuffle, repeat and auto next. Either a
// context (spotify:playlist:..., or spotify:collection for Liked Songs) from startURI, or a list of track URIs from
// startIndex. Starts `position` seconds into that track.
- (void)playContext:(NSString *)contextURI tracks:(NSArray *)trackURIs startURI:(NSString *)startURI startIndex:(NSUInteger)startIndex shuffle:(BOOL)shuffle position:(NSTimeInterval)position completion:(void(^)(NSError *error))completion;
- (void)prepareAudioSession;
// Announces Retrofy as a Spotify Connect device, picking it in the Spotify app on another device logs in.
// Posts FMLibrespotDidLogInNotification (userInfo username) or shows the error.
- (BOOL)startLibrespotDiscoveryWithError:(NSError **)error;
- (void)stopLibrespotDiscovery;
// Whether librespot has a Spotify Connect login (playback works).
@property (readonly, nonatomic) BOOL librespotHasLogin;
// Serves the Web API login page (for the user's own client ID) on the Wi-Fi and returns its address,
// e.g. http://192.168.1.238:8080. Posts FMWebAPIDidLogInNotification once logged in.
- (NSString *)startWebAPILoginWithError:(NSError **)error;
- (void)stopWebAPILogin;
- (void)librespotPause;
- (void)librespotResume;
- (void)librespotRewind;
- (void)librespotSeekToPosition:(NSTimeInterval)position;
- (void)librespotNext;
- (void)librespotPrevious;
- (void)librespotSetShuffle:(BOOL)shuffle;
// 0 off, 1 repeat the context, 2 repeat the track.
- (void)librespotSetRepeat:(NSUInteger)mode;
// A page of a playlist's tracks through librespot, for playlists the Web API answers with 403. The page is
// shaped like a Web API playlist items page, with next_offset (NSNumber, or NSNull at the end). Calls back on the main queue.
- (void)loadPlaylistTracksWithLibrespot:(NSString *)playlistID offset:(NSUInteger)offset limit:(NSUInteger)limit completion:(void(^)(NSDictionary *page, NSError *error))completion;

@end
