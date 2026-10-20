//
//  FMSpotifyLibrary.h
//  FoxMusic
//
//  Liked Songs and adding to playlists, through the Web API's library endpoints (February 2026 versions:
//  /me/library takes URIs, playlist items live at /playlists/{id}/items).
//

#import <Foundation/Foundation.h>

#import "FMAppDelegate.h"

// Posted on the main thread when a track was added to or removed from Liked Songs, object is the track.
extern NSString *const FMSpotifyLibraryDidChangeNotification;
// Posted when the Web API login was dropped so the user can log in again (to grant new permissions).
extern NSString *const FMWebAPIDidLogOutNotification;

// Error code for a login from before FoxMusic asked for permission to change the library.
extern const NSInteger FMSpotifyLibraryNeedsLoginErrorCode;

@interface FMSpotifyLibrary : NSObject

+ (FMSpotifyLibrary *)sharedLibrary;

// The last known state, or nil when it isn't known yet.
- (NSNumber *)isTrackSaved:(FMSpotifyTrack *)track;
- (void)checkTrackSaved:(FMSpotifyTrack *)track completion:(void(^)(BOOL saved, NSError *error))completion;
// Looks up the state of tracks shown in a list. Calls made close together are sent as one request per 40
// tracks, FMSpotifyLibraryDidChangeNotification (object nil) follows when the answers are in.
- (void)requestSavedStateForTracks:(NSArray *)tracks;
// For tracks known to be saved, like the ones in Liked Songs, without asking Spotify.
- (void)rememberTracks:(NSArray *)tracks saved:(BOOL)saved;
- (void)setTrack:(FMSpotifyTrack *)track saved:(BOOL)saved completion:(void(^)(NSError *error))completion;
- (void)addTrack:(FMSpotifyTrack *)track toPlaylist:(FMSpotifyPlaylist *)playlist completion:(void(^)(NSError *error))completion;

// Forgets the Web API login, so the login page asks again with the current permissions.
- (void)logOutOfWebAPI;

@end
