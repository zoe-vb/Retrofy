//
//  FMSpotifyContent.m
//  Retrofy
//
//  What only librespot can get: Your Library with Spotify's own playlists, lyrics and the AI DJ. Everything here
//  needs the Spotify Connect login, and calls back on the main thread.
//

#import "FMSpotifyContent.h"

#import "FMURLConnection.h"

#ifdef FM_LIBRESPOT
#import "fmlibrespot.h"
#endif

// Canvases kept on disk, they're a few MB each.
static const NSUInteger FMCanvasMaximumFiles = 10;

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

#ifdef FM_LIBRESPOT
+ (NSString *)canvasDirectory
{
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString *directory = [caches stringByAppendingPathComponent:@"Canvas"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return directory;
}

// Keeps the most recently saved ones.
+ (void)trimCanvasFiles
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *directory = [self canvasDirectory];
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *name in [fileManager contentsOfDirectoryAtPath:directory error:nil]) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        NSDate *date = [[fileManager attributesOfItemAtPath:path error:nil] fileModificationDate];
        if (date) [files addObject:@{@"path": path, @"date": date}];
    }
    [files sortUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
        return [[second objectForKey:@"date"] compare:[first objectForKey:@"date"]];
    }];
    for (NSUInteger index = FMCanvasMaximumFiles; index < files.count; index++) {
        [fileManager removeItemAtPath:[[files objectAtIndex:index] objectForKey:@"path"] error:nil];
    }
}
#endif

+ (void)loadCanvasForTrack:(FMSpotifyTrack *)track completion:(void (^)(NSURL *))completion
{
#ifdef FM_LIBRESPOT
    static NSMutableSet *tracksWithoutCanvas;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tracksWithoutCanvas = [NSMutableSet set];
    });

    NSString *identifier = track.identifier;
    if (!identifier || [tracksWithoutCanvas containsObject:identifier]) {
        completion(nil);
        return;
    }
    NSString *path = [[[self canvasDirectory] stringByAppendingPathComponent:identifier] stringByAppendingPathExtension:@"mp4"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        completion([NSURL fileURLWithPath:path]);
        return;
    }

    NSString *uri = [@"spotify:track:" stringByAppendingString:identifier];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        char *url = NULL;
        char *error = NULL;
        BOOL found = fm_librespot_canvas([uri UTF8String], &url, &error);
        NSString *address = found ? [NSString stringWithUTF8String:url] : nil;
        NSString *message = error ? [NSString stringWithUTF8String:error] : nil;
        fm_librespot_free_string(url);
        fm_librespot_free_string(error);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!address) {
                if ([message isEqualToString:@"No Canvas"]) [tracksWithoutCanvas addObject:identifier];
                else NSLog(@"%@", message);
                completion(nil);
                return;
            }
            FMSendRustlsRequest(@"GET", [NSURL URLWithString:address], nil, ^(NSData *data) {
                // An MP4 has "ftyp" here, anything else is an error page.
                BOOL isVideo = data.length > 8 && memcmp((const char *)data.bytes + 4, "ftyp", 4) == 0;
                if (!isVideo || ![data writeToFile:path atomically:YES]) {
                    completion(nil);
                    return;
                }
                [self trimCanvasFiles];
                completion([NSURL fileURLWithPath:path]);
            });
        });
    });
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
