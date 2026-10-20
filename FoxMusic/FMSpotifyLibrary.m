//
//  FMSpotifyLibrary.m
//  FoxMusic
//
//  Liked Songs and adding to playlists, through the Web API's library endpoints (February 2026 versions:
//  /me/library takes URIs, playlist items live at /playlists/{id}/items).
//

#import "FMSpotifyLibrary.h"

#import "FMSpotifyToken.h"
#import "FMURLConnectionDelegate.h"

NSString *const FMSpotifyLibraryDidChangeNotification = @"FMSpotifyLibraryDidChangeNotification";
NSString *const FMWebAPIDidLogOutNotification = @"FMWebAPIDidLogOutNotification";
const NSInteger FMSpotifyLibraryNeedsLoginErrorCode = 4031;

// Set when the user logged in again for the library permissions, so a login that still lacks them isn't
// answered with the same "log in again" over and over.
static NSString *const FMSpotifyLibraryAskedForLoginKey = @"FMSpotifyLibraryAskedForLogin";

// The most URIs /me/library/contains takes at once.
static const NSUInteger FMSpotifyLibraryContainsLimit = 40;

@interface FMSpotifyLibrary ()
{
    // Saved state by track ID.
    NSMutableDictionary *_savedTracks;
    // Track IDs waiting to be looked up, and the ones being looked up.
    NSMutableOrderedSet *_queuedTrackIDs;
    NSMutableSet *_pendingTrackIDs;
}
@end

@implementation FMSpotifyLibrary

+ (FMSpotifyLibrary *)sharedLibrary
{
    static FMSpotifyLibrary *sharedLibrary;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedLibrary = [[FMSpotifyLibrary alloc] init];
    });
    return sharedLibrary;
}

- (id)init
{
    self = [super init];
    if (self) {
        _savedTracks = [NSMutableDictionary dictionary];
        _queuedTrackIDs = [NSMutableOrderedSet orderedSet];
        _pendingTrackIDs = [NSMutableSet set];
    }
    return self;
}

- (FMSpotifyClient *)spotifyClient
{
    return [(FMAppDelegate *)[[UIApplication sharedApplication] delegate] spotifyClient];
}

- (NSError *)needsLoginError
{
    if ([[NSUserDefaults standardUserDefaults] boolForKey:FMSpotifyLibraryAskedForLoginKey]) {
        // Logging in again didn't help: the login page itself doesn't ask for these permissions.
        NSString *scopes = self.spotifyClient.token.scope ?: @"none";
        return [NSError errorWithDomain:@"spotify_library" code:4032 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Missing permission", NSLocalizedDescriptionKey: [NSString stringWithFormat:@"The Spotify login page didn't ask for permission to change your library, so logging in again won't help. This build's libfmlibrespot.a is older than the change to webapi_login.rs that asks for it: rebuild it with build-ios6.sh, rebuild the app, then log in again.\n\nThis login allows: %@", scopes]}];
    }
    return [NSError errorWithDomain:@"spotify_library" code:FMSpotifyLibraryNeedsLoginErrorCode userInfo:@{NSLocalizedFailureReasonErrorKey: @"Log in again", NSLocalizedDescriptionKey: @"FoxMusic needs permission to change your Liked Songs and playlists. Log in to Spotify again to allow it."}];
}

// Whether the login allows `scope`. Logins without a scope list are tried anyway.
- (BOOL)loginHasScope:(NSString *)scope
{
    NSString *scopes = self.spotifyClient.token.scope;
    if (![scopes isKindOfClass:[NSString class]] || !scopes.length) return YES;
    BOOL hasScope = [[scopes componentsSeparatedByString:@" "] containsObject:scope];
    if (hasScope) [[NSUserDefaults standardUserDefaults] removeObjectForKey:FMSpotifyLibraryAskedForLoginKey];
    return hasScope;
}

+ (NSString *)uriForTrack:(FMSpotifyTrack *)track
{
    return track.identifier ? [@"spotify:track:" stringByAppendingString:track.identifier] : nil;
}

// A Web API request with the login's token. Calls back on the main thread with the parsed JSON (nil for an
// empty response) or an error.
- (void)send:(NSString *)method path:(NSString *)path completion:(void(^)(id response, NSError *error))completion
{
    FMSpotifyClient *client = self.spotifyClient;
    // Access tokens only last an hour.
    if (![client isLoggedIn] && client.token.refreshToken) [client refreshTokenWithError:nil];
    NSString *bearer = [client.token bearer];
    if (!bearer) {
        completion(nil, [NSError errorWithDomain:@"not_logged_in" code:401 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Not logged in", NSLocalizedDescriptionKey: @"Log in to Spotify first."}]);
        return;
    }

    NSURL *url = [NSURL URLWithString:[@"https://api.spotify.com/v1/" stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:method];
    [request setValue:bearer forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (![method isEqualToString:@"GET"]) {
        // Everything is in the query, but PUT and POST still need a (zero) length.
        [request setHTTPBody:[NSData data]];
        [request setValue:@"0" forHTTPHeaderField:@"Content-Length"];
    }

    FMURLConnectionDelegate *delegate = [FMURLConnectionDelegate urlConnectionControllerWithCallback:^(NSData *data){
        if (!data) {
            completion(nil, [NSError errorWithDomain:@"network_error" code:1001 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Network error", NSLocalizedDescriptionKey: @"The request to Spotify failed."}]);
            return;
        }
        id response = data.length ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:nil] : nil;
        NSDictionary *errorObject = [response isKindOfClass:[NSDictionary class]] ? [response objectForKey:@"error"] : nil;
        if ([errorObject isKindOfClass:[NSDictionary class]]) {
            NSInteger status = [[errorObject objectForKey:@"status"] integerValue];
            NSString *message = [errorObject objectForKey:@"message"];
            if (![message isKindOfClass:[NSString class]]) message = @"Spotify refused the request.";
            if (status == 403 && [[message lowercaseString] rangeOfString:@"scope"].location != NSNotFound) {
                completion(nil, [self needsLoginError]);
                return;
            }
            completion(nil, [NSError errorWithDomain:[NSString stringWithFormat:@"http_%d", (int)status] code:status userInfo:@{NSLocalizedFailureReasonErrorKey: @"Spotify error", NSLocalizedDescriptionKey: message}]);
            return;
        }
        completion(response, nil);
    }];
    [[[NSURLConnection alloc] initWithRequest:request delegate:delegate] start];
}

- (NSNumber *)isTrackSaved:(FMSpotifyTrack *)track
{
    return track.identifier ? [_savedTracks objectForKey:track.identifier] : nil;
}

- (void)checkTrackSaved:(FMSpotifyTrack *)track completion:(void (^)(BOOL, NSError *))completion
{
    NSString *uri = [FMSpotifyLibrary uriForTrack:track];
    if (!uri) return;
    NSString *path = [@"me/library/contains?uris=" stringByAppendingString:[uri stringByReplacingOccurrencesOfString:@":" withString:@"%3A"]];
    [self send:@"GET" path:path completion:^(id response, NSError *error){
        BOOL saved = [response isKindOfClass:[NSArray class]] && [response count] && [[response objectAtIndex:0] boolValue];
        if (!error) [_savedTracks setObject:@(saved) forKey:track.identifier];
        if (completion) completion(saved, error);
    }];
}

- (void)requestSavedStateForTracks:(NSArray *)tracks
{
    for (FMSpotifyTrack *track in tracks) {
        NSString *identifier = track.identifier;
        if (!identifier || [_savedTracks objectForKey:identifier] || [_pendingTrackIDs containsObject:identifier]) continue;
        [_queuedTrackIDs addObject:identifier];
    }
    if (!_queuedTrackIDs.count) return;
    // Rows appear one by one while scrolling, gather them first.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sendQueuedRequests) object:nil];
    [self performSelector:@selector(sendQueuedRequests) withObject:nil afterDelay:0.3];
}

- (void)sendQueuedRequests
{
    NSArray *identifiers = [_queuedTrackIDs array];
    [_queuedTrackIDs removeAllObjects];
    for (NSUInteger start = 0; start < identifiers.count; start += FMSpotifyLibraryContainsLimit) {
        NSArray *batch = [identifiers subarrayWithRange:NSMakeRange(start, MIN(FMSpotifyLibraryContainsLimit, identifiers.count - start))];
        [_pendingTrackIDs addObjectsFromArray:batch];
        NSMutableArray *uris = [NSMutableArray arrayWithCapacity:batch.count];
        for (NSString *identifier in batch) [uris addObject:[@"spotify%3Atrack%3A" stringByAppendingString:identifier]];

        [self send:@"GET" path:[@"me/library/contains?uris=" stringByAppendingString:[uris componentsJoinedByString:@","]] completion:^(id response, NSError *error){
            for (NSString *identifier in batch) [_pendingTrackIDs removeObject:identifier];
            if (error || ![response isKindOfClass:[NSArray class]]) {
                NSLog(@"Couldn't look up Liked Songs: %@", error.localizedDescription);
                return;
            }
            [batch enumerateObjectsUsingBlock:^(NSString *identifier, NSUInteger index, BOOL *stop){
                if (index < [response count]) [_savedTracks setObject:@([[response objectAtIndex:index] boolValue]) forKey:identifier];
            }];
            [[NSNotificationCenter defaultCenter] postNotificationName:FMSpotifyLibraryDidChangeNotification object:nil];
        }];
    }
}

- (void)rememberTracks:(NSArray *)tracks saved:(BOOL)saved
{
    for (FMSpotifyTrack *track in tracks) {
        if (track.identifier && ![_savedTracks objectForKey:track.identifier]) [_savedTracks setObject:@(saved) forKey:track.identifier];
    }
}

- (void)setTrack:(FMSpotifyTrack *)track saved:(BOOL)saved completion:(void (^)(NSError *))completion
{
    NSString *uri = [FMSpotifyLibrary uriForTrack:track];
    if (!uri) return;
    if (![self loginHasScope:@"user-library-modify"]) {
        if (completion) completion([self needsLoginError]);
        return;
    }
    NSNumber *previous = [_savedTracks objectForKey:track.identifier];
    // Shows the change right away, and undoes it if Spotify refuses.
    [_savedTracks setObject:@(saved) forKey:track.identifier];
    [[NSNotificationCenter defaultCenter] postNotificationName:FMSpotifyLibraryDidChangeNotification object:track];

    NSString *path = [@"me/library?uris=" stringByAppendingString:[uri stringByReplacingOccurrencesOfString:@":" withString:@"%3A"]];
    [self send:saved ? @"PUT" : @"DELETE" path:path completion:^(id response, NSError *error){
        if (error) {
            if (previous) [_savedTracks setObject:previous forKey:track.identifier];
            else [_savedTracks removeObjectForKey:track.identifier];
            [[NSNotificationCenter defaultCenter] postNotificationName:FMSpotifyLibraryDidChangeNotification object:track];
        }
        if (completion) completion(error);
    }];
}

- (void)addTrack:(FMSpotifyTrack *)track toPlaylist:(FMSpotifyPlaylist *)playlist completion:(void (^)(NSError *))completion
{
    NSString *uri = [FMSpotifyLibrary uriForTrack:track];
    if (!uri || !playlist.identifier) return;
    if (![self loginHasScope:@"playlist-modify-public"] && ![self loginHasScope:@"playlist-modify-private"]) {
        if (completion) completion([self needsLoginError]);
        return;
    }
    NSString *path = [NSString stringWithFormat:@"playlists/%@/items?uris=%@", playlist.identifier, [uri stringByReplacingOccurrencesOfString:@":" withString:@"%3A"]];
    [self send:@"POST" path:path completion:^(id response, NSError *error){
        if (completion) completion(error);
    }];
}

- (void)logOutOfWebAPI
{
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in @[FMSpotifyTokenAccessTokenKey, FMSpotifyTokenExpiresInKey, FMSpotifyTokenRefreshTokenKey, FMSpotifyTokenScopeKey, FMSpotifyTokenTokenTypeKey, FMSpotifyTokenCreatedOnKey])
        [userDefaults removeObjectForKey:key];
    [userDefaults setBool:YES forKey:FMSpotifyLibraryAskedForLoginKey];
    [userDefaults synchronize];
    self.spotifyClient.token = [FMSpotifyToken tokenWithDictionary:@{}];
    [_savedTracks removeAllObjects];
    [[NSNotificationCenter defaultCenter] postNotificationName:FMWebAPIDidLogOutNotification object:self];
}

@end
