//
//  FMSpotifyContent.h
//  Retrofy
//
//  What only librespot can get: Your Library with Spotify's own playlists, lyrics and the AI DJ. Everything here
//  needs the Spotify Connect login, and calls back on the main thread.
//

#import <Foundation/Foundation.h>

#import "FMAppDelegate.h"

@interface FMSpotifyContent : NSObject

// A new Liked Songs list. It isn't a real playlist, so it loads through the Web API like one.
+ (FMSpotifyPlaylist *)likedSongsPlaylist;

// FMSpotifyPlaylists, with Spotify's Daily Mixes, Top Songs and so on that the Web API leaves out.
+ (void)loadLibraryPlaylists:(void(^)(NSArray *playlists, NSError *error))completion;

// Spotify's lyrics response, nil when the track has none. Cached per track.
+ (void)loadLyricsForTrack:(FMSpotifyTrack *)track completion:(void(^)(NSDictionary *lyrics))completion;

// A page of the AI DJ. pageURL nil starts a session.
+ (void)loadDJPage:(NSString *)pageURL completion:(void(^)(NSDictionary *page, NSError *error))completion;

+ (void)loadTracks:(NSArray *)trackURIs completion:(void(^)(FMSpotifyTrackArray *tracks))completion;

@end
