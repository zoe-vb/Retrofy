//
//  FMSpotifyContent.m
//  Retrofy
//
//  What only librespot can get: Your Library with Spotify's own playlists, lyrics and the AI DJ. Everything here
//  needs the Spotify Connect login, and calls back on the main thread.
//

#import "FMSpotifyContent.h"

#ifdef FM_LIBRESPOT
#import "fmlibrespot.h"
#endif

@implementation FMSpotifyContent

+ (FMSpotifyPlaylist *)likedSongsPlaylist
{
    FMSpotifyPlaylist *playlist = [[FMSpotifyPlaylist alloc] init];
    playlist.name = @"Liked Songs";
    playlist.identifier = @"liked-songs";
    playlist.tracks = [FMSpotifyTrackArray trackArrayWithDictionary:@{@"href": @"https://api.spotify.com/v1/me/tracks?limit=50"}];
    return playlist;
}

#ifdef FM_LIBRESPOT
// Runs one of the blocking JSON calls off the main thread.
+ (void)load:(bool (^)(char **json, char **error))call completion:(void(^)(id json, NSError *error))completion
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        char *json = NULL;
        char *callError = NULL;
        id result = nil;
        NSError *error = nil;
        if (call(&json, &callError)) {
            NSData *data = [NSData dataWithBytes:json length:strlen(json)];
            fm_librespot_free_string(json);
            result = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        } else {
            NSString *message = callError ? [NSString stringWithUTF8String:callError] : @"Unknown error";
            fm_librespot_free_string(callError);
            error = [NSError errorWithDomain:@"librespot" code:12 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Spotify error", NSLocalizedDescriptionKey: message}];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(result, error);
        });
    });
}
#endif

+ (void)loadLibraryPlaylists:(void (^)(NSArray *, NSError *))completion
{
#ifdef FM_LIBRESPOT
    [self load:^bool(char **json, char **error) {
        return fm_librespot_rootlist(json, error);
    } completion:^(id entries, NSError *error) {
        if (![entries isKindOfClass:[NSArray class]]) {
            completion(nil, error);
            return;
        }
        NSMutableArray *playlists = [NSMutableArray array];
        for (NSDictionary *entry in entries) {
            NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithDictionary:entry];
            NSString *image = [entry objectForKey:@"image"];
            if ([image hasPrefix:@"http"]) [dictionary setObject:@[@{@"url": image}] forKey:@"images"];
            [playlists addObject:[FMSpotifyPlaylist playlistFromDictionary:dictionary]];
        }
        completion(playlists, nil);
    }];
#else
    completion(nil, nil);
#endif
}

+ (void)loadLyricsForTrack:(FMSpotifyTrack *)track completion:(void (^)(NSDictionary *))completion
{
#ifdef FM_LIBRESPOT
    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
    });

    NSString *identifier = track.identifier;
    if (!identifier) {
        completion(nil);
        return;
    }
    id cached = [cache objectForKey:identifier];
    if (cached) {
        completion(cached == [NSNull null] ? nil : cached);
        return;
    }
    NSString *uri = [@"spotify:track:" stringByAppendingString:identifier];
    [self load:^bool(char **json, char **error) {
        return fm_librespot_lyrics([uri UTF8String], json, error);
    } completion:^(id lyrics, NSError *error) {
        BOOL found = [lyrics isKindOfClass:[NSDictionary class]];
        [cache setObject:found ? lyrics : [NSNull null] forKey:identifier];
        completion(found ? lyrics : nil);
    }];
#else
    completion(nil);
#endif
}

+ (void)loadDJPage:(NSString *)pageURL completion:(void (^)(NSDictionary *, NSError *))completion
{
#ifdef FM_LIBRESPOT
    [self load:^bool(char **json, char **error) {
        return fm_librespot_dj_session([pageURL UTF8String], json, error);
    } completion:^(id page, NSError *error) {
        completion([page isKindOfClass:[NSDictionary class]] ? page : nil, error);
    }];
#else
    completion(nil, nil);
#endif
}

+ (void)loadTracks:(NSArray *)trackURIs completion:(void (^)(FMSpotifyTrackArray *))completion
{
#ifdef FM_LIBRESPOT
    NSString *uris = [NSString stringWithFormat:@"[\"%@\"]", [trackURIs componentsJoinedByString:@"\",\""]];
    [self load:^bool(char **json, char **error) {
        return fm_librespot_tracks([uris UTF8String], json, error);
    } completion:^(id page, NSError *error) {
        completion([page isKindOfClass:[NSDictionary class]] ? [FMSpotifyTrackArray trackArrayWithDictionary:page] : nil);
    }];
#else
    completion(nil);
#endif
}

@end
