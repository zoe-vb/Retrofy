//
//  FMSpotifyClient.m
//  FoxMusic
//
//  Created by Lasse Lauwerys on 27/06/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import "FMSpotifyClient.h"
#import "FMMutableURLQueryDictionary.h"
#import "FMURLConnectionDelegate.h"
#import "FMSpotifyPlaylistArray.h"
#import "FMBase62Decoder.h"

#ifdef FM_LIBRESPOT
#import "fmlibrespot.h"
#endif

@interface FMSpotifyClient ()

@end

@interface NSURLRequest (DummyInterface)
+ (BOOL)allowsAnyHTTPSCertificateForHost:(NSString *)host;
+ (void)setAllowsAnyHTTPSCertificate:(BOOL)allow forHost:(NSString *)host;
@end

@implementation FMSpotifyClient

- (id)init
{
    self = [super init];
    if (self) {
        // Use your own Spotify app's client ID (FMSpotifyClientID in the Info.plist). The default one belongs
        // to the original developer, is shared by every FoxMusic install and runs into QUOTA_EXCEEDED.
        NSString *configuredClientId = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"FMSpotifyClientID"];
        self.clientId = [configuredClientId isKindOfClass:[NSString class]] && [configuredClientId length] ? configuredClientId : @"756a522d9f1648b89e76e80be654456a";
        
        
        NSString *accountsBaseAddress = @"https://accounts.spotify.com";
        NSString *authorizeDeviceEndpoint = @"oauth2/device/authorize";
        NSString *tokenEndpoint = @"api/token";
        NSString *apiBaseAddress = @"https://api.spotify.com/v1";
        NSString *searchEndpoint = @"search";
        
        self.accountsBaseAddress = [NSURL URLWithString:accountsBaseAddress];
        self.authorizeDeviceEndpoint = [self.accountsBaseAddress URLByAppendingPathComponent:authorizeDeviceEndpoint];
        self.tokenEndpoint = [self.accountsBaseAddress URLByAppendingPathComponent:tokenEndpoint];
        
        self.apiBaseAddress = [NSURL URLWithString:apiBaseAddress];
        self.searchEndpoint = [self.apiBaseAddress URLByAppendingPathComponent:searchEndpoint];
        
        self.token = [FMSpotifyToken savedToken];
#ifdef FM_LIBRESPOT
        // A token without refresh token came from librespot's login5 in an earlier build. It runs into
        // the shared client ID's quota, so log in again through the Web API login page instead.
        if (!self.token.refreshToken) self.token = [FMSpotifyToken tokenWithDictionary:@{}];
#endif
        
//        apiParser = [FMSpotifyAPIParser apiParser];
    }
    return self;
}

- (NSDictionary *)request:(NSURL *)url withBody:(NSDictionary *)requestBody
{
    return [self request:url withBody:requestBody addClientId:YES error:nil];
}

- (NSDictionary *)request:(NSURL *)url withBody:(NSDictionary *)requestBody error:(NSError **)error
{
    return [self request:url withBody:requestBody addClientId:YES error:error];
}

- (NSDictionary *)request:(NSURL *)url withBody:(NSDictionary *)requestBody addClientId:(BOOL)injectClientId
{
    return [self request:url withBody:requestBody addClientId:injectClientId error:nil];
}

- (NSDictionary *)request:(NSURL *)url withBody:(NSDictionary *)requestBody addClientId:(BOOL)injectClientId error:(NSError **)error
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    
    [request setHTTPMethod:@"POST"];
    
    FMMutableURLQueryDictionary *body = [FMMutableURLQueryDictionary urlQueryDictionary];
    
    if (injectClientId) [body addEntriesFromDictionary:@{@"client_id": self.clientId}];
    [body addEntriesFromDictionary:requestBody];
    [request setHTTPBody:[body urlEncodedData]];
    
    NSLog(@"POST %@", url);
    
    [request addValue:@(request.HTTPBody.length).stringValue forHTTPHeaderField:@"Content-Length"];
    [request addValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    
    NSError *requestError;

#ifdef FM_LIBRESPOT
    // accounts.spotify.com only offers AES-GCM cipher suites, which iOS 6's TLS doesn't support,
    // so the handshake fails. The Rust library's TLS stack (rustls) can talk to it.
    NSData *responseData = [self sendRustlsRequest:request error:&requestError];
#else
    NSURLResponse *response;
    [NSURLRequest setAllowsAnyHTTPSCertificate:YES forHost:@"api.spotify.com"];

    NSData *responseData = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&requestError];
#endif

    NSDictionary *result;
	if (!requestError) {
        result = [self parseResponseData:responseData error:&requestError];
        [self checkResult:result forError:&requestError];
	}
    
    if (error) *error = requestError;
    
    return result;
}

#ifdef FM_LIBRESPOT
- (NSData *)sendRustlsRequest:(NSURLRequest *)request error:(NSError **)error
{
    int status = 0;
    uint8_t *body = NULL;
    size_t bodyLength = 0;
    char *requestError = NULL;
    NSData *requestBody = [request HTTPBody];

    BOOL success = fm_https_request([[request HTTPMethod] UTF8String],
                                    [[[request URL] absoluteString] UTF8String],
                                    [[request valueForHTTPHeaderField:@"Content-Type"] UTF8String],
                                    [[request valueForHTTPHeaderField:@"Authorization"] UTF8String],
                                    [requestBody bytes],
                                    [requestBody length],
                                    &status, &body, &bodyLength, &requestError);

    if (!success) {
        NSString *message = requestError ? [NSString stringWithUTF8String:requestError] : @"Unknown error";
        fm_librespot_free_string(requestError);
        if (error) *error = [NSError errorWithDomain:@"network_error" code:1001 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Couldn't reach Spotify", NSLocalizedDescriptionKey: message}];
        return nil;
    }

    NSData *data = [NSData dataWithBytes:body length:bodyLength];
    fm_librespot_free_buffer(body, bodyLength);
    NSLog(@"%@ %@ -> HTTP %d", [request HTTPMethod], [request URL], status);
    return data;
}
#endif

- (id)parseResponseData:(NSData *)data error:(NSError **)error
{
    id response;
    NSError *serializationError;

    if (!data) data = [NSData data];

    @try {
        response = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:&serializationError];

        if (serializationError) {
            // Some responses contain invalid UTF-8. Re-encode lossily and try once more,
            // without touching any characters JSON relies on (escapes, & in next URLs, ...).
            NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (!string) string = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
            NSData *repairedData = [string dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
            if (repairedData) {
                NSError *retryError;
                id retryResponse = [NSJSONSerialization JSONObjectWithData:repairedData options:NSJSONReadingAllowFragments error:&retryError];
                if (!retryError) {
                    response = retryResponse;
                    serializationError = nil;
                }
            }
        }
    } @catch (NSException *ex) {
        serializationError = [NSError errorWithDomain:@"parsingResponse" code:1009 userInfo:@{NSLocalizedDescriptionKey: ex.description, NSLocalizedFailureReasonErrorKey: ex.reason}];
        
    }
    
    if (error) {
        *error = serializationError;
    }
    return response;
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    NSLog(@"ERROR ERROR FUCKER: %@", error.localizedDescription);
}

- (void)request:(NSURL *)url callback:(void (^const)(NSDictionary *, NSError *))callback
{
    if (!url) {
        NSLog(@"Unable to make request. No URL provided");
        return;
    }
    // Access tokens only last an hour, refresh before the request instead of failing with a 401.
    if (![self isLoggedIn] && self.token.refreshToken) {
        NSError *refreshError;
        [self refreshTokenWithError:&refreshError];
        if (refreshError) {
            callback(@{}, refreshError);
            return;
        }
    }

    NSString *bearer = [[self token] bearer];
    if (!bearer) {
        callback(@{}, [NSError errorWithDomain:@"not_logged_in" code:401 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Not logged in", NSLocalizedDescriptionKey: @"Log in to Spotify first."}]);
        return;
    }

    [self getDataFromURL:url withCallback:^(NSData *data){
        NSError *error;
        if (!data) {
            callback(@{}, [NSError errorWithDomain:@"network_error" code:1001 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Network error", NSLocalizedDescriptionKey: @"The request to Spotify failed."}]);
            return;
        }
        NSDictionary *result = [self parseResponseData:data error:&error];
        if (![result isKindOfClass:[NSDictionary class]]) result = @{};
        if (!error) [self checkResult:result forError:&error];
        callback(result, error);
    } andHeaders:@{@"Authorization": bearer, @"Accept": @"application/json"}];
}

//- (void)getDataFromURL:(NSURL *)url withCallback:(void(^)(NSData *data))callback
//{
//    [[[NSURLConnection alloc] initWithRequest:[NSURLRequest requestWithURL:url] delegate:[FMURLConnectionDelegate urlConnectionControllerWithCallback:callback]] start];
//}
//
//- (void)getDataFromURL:(NSURL *)url withCallback:(void (^)(NSData *))callback andHeaders:(NSDictionary *)headers
//{
//    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
//    for (NSString *headerField in headers) [request addValue:[headers objectForKey:headerField] forHTTPHeaderField:headerField];
//    [[[NSURLConnection alloc] initWithRequest:request delegate:[FMURLConnectionDelegate urlConnectionControllerWithCallback:callback]] start];
//}

- (NSURL *)makeEndpointURL:(NSString *)endpoint
{
    return [self.apiBaseAddress URLByAppendingPathComponent:endpoint];
}

- (void)getUserPlaylistsAndWhenSuccess:(void (^)(FMSpotifyPlaylistArray *))callbackSuccess whenError:(void (^)(NSError *))callbackError
{
    NSURL *playlistsEndpoint = [self makeEndpointURL:@"me/playlists"];
    
    [self request:playlistsEndpoint callback:^(NSDictionary *result, NSError *error){
        if (!error) {
            
            callbackSuccess([FMSpotifyPlaylistArray playlistArrayWithDictionary:result]);
        } else callbackError(error);
    }];
}

- (BOOL)checkResult:(NSDictionary *)result forError:(NSError **)error
{
    if (![result isKindOfClass:[NSDictionary class]]) return NO;

    id errorReason = [result objectForKey:@"error"];
    id errorDescription = [result objectForKey:@"error_description"];
    NSInteger code = 6942;

    // The Web API returns {"error": {"status": 401, "message": "..."}}, the accounts service returns strings.
    if ([errorReason isKindOfClass:[NSDictionary class]]) {
        NSDictionary *errorObject = errorReason;
        id status = [errorObject objectForKey:@"status"];
        if ([status respondsToSelector:@selector(integerValue)]) code = [status integerValue];
        errorDescription = [errorObject objectForKey:@"message"];
        errorReason = [NSString stringWithFormat:@"http_%d", (int)code];
    }
    if (![errorReason isKindOfClass:[NSString class]]) errorReason = nil;
    if (![errorDescription isKindOfClass:[NSString class]]) errorDescription = nil;

    BOOL isError = errorReason || errorDescription;
    if (error && isError) {
        NSError *newError = [NSError errorWithDomain:errorReason ? errorReason : @"spotify_error" code:code userInfo:@{
                                               NSLocalizedDescriptionKey: errorDescription ? errorDescription : @"Unknown description",
                                        NSLocalizedFailureReasonErrorKey: errorReason ? errorReason : @"Spotify error"
                                                 }];
        *error = [self localizeError:newError];
    }
    return isError;
}

- (NSError *)localizeError:(NSError *)error
{
//    NSError *localizedError = error;
//    NSDictionary *userInfo;
    NSString *failureReason = error.localizedFailureReason ? error.localizedFailureReason : @"Spotify error";
    NSString *description = error.localizedDescription ? error.localizedDescription : @"Unknown description";
    if ([error.domain isEqualToString:@"authorization_pending"]) failureReason = @"Authorization pending", description = @"The code has not yet been used. Enter it on the Spotify website, then try again.";
    if ([error.domain isEqualToString:@"slow_down"]) failureReason = @"Slow down", description = @"Wait a few seconds before trying again.";
    if ([error.domain isEqualToString:@"expired_token"]) failureReason = @"Code expired", description = @"The code has expired, get a new one.";
    if ([error.domain isEqualToString:@"access_denied"]) failureReason = @"Access denied", description = @"The login was declined.";
    if ([error.domain isEqualToString:@"invalid_grant"]) failureReason = @"Refresh token revoked", description = @"The saved login is no longer valid, please log in again.";
    if ([error.domain isEqualToString:@"http_401"]) failureReason = @"Not authorized", description = @"The Spotify login expired, please log in again.";
    return [NSError errorWithDomain:error.domain code:error.code userInfo:@{NSLocalizedFailureReasonErrorKey: failureReason, NSLocalizedDescriptionKey: description}];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    NSLog(@"Recieved data!!: %@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    NSLog(@"Connection finished!");
}

- (FMSpotifyDeviceAuthorizationInfo *)refreshDeviceAuthorizationInfoWithError:(NSError **)error
{
	NSError *requestError;
    NSDictionary *response = [self request:self.authorizeDeviceEndpoint withBody:@{@"scope": @"streaming user-read-private user-read-email playlist-read-private playlist-read-collaborative user-library-read"} error:&requestError];
	if (error) *error = requestError;
    if (requestError || ![response isKindOfClass:[NSDictionary class]]) return nil;
    return self.deviceAuthorizationInfo = [FMSpotifyDeviceAuthorizationInfo deviceAuthorizationInfoFromDictionary:response];
}

- (BOOL)tryDeviceAuhorization
{
    return [self tryDeviceAuhorizationWithError:nil];
}

- (BOOL)tryDeviceAuhorizationWithError:(NSError **)error
{
    NSError *requestError;
    
    NSString *deviceCode = self.deviceAuthorizationInfo.deviceCode;

    if (!deviceCode) {
        if (error) *error = [NSError errorWithDomain:@"missing_device_code" code:1002 userInfo:@{NSLocalizedFailureReasonErrorKey: @"Authorization failed", NSLocalizedDescriptionKey: @"No login code was requested yet, get a new code first."}];
        return NO;
    }

    NSDictionary *body = @{
                           @"grant_type": @"urn:ietf:params:oauth:grant-type:device_code",
                           @"device_code": deviceCode
                           };

    NSDictionary *response = [self request:self.tokenEndpoint withBody:body error:&requestError];

    NSLog(@"Device authorization %@", requestError ? requestError.domain : @"succeeded");

    if (error) *error = requestError;

    // A pending/failed authorization must not replace the saved token.
    if (!requestError) [self setTokenFromDictionary:response];

    return [self isLoggedIn];
}

- (BOOL)refreshToken
{
    return [self refreshTokenWithError:nil];
}

- (BOOL)refreshTokenWithError:(NSError **)error
{
    NSError *requestError;

    // With FM_LIBRESPOT this is the refresh token from the Web API login page (FMSpotifyClientID's own
    // quota). librespot's login5 tokens aren't used for the Web API: they belong to librespot's shared
    // client ID, whose Web API quota is used up (429). The refresh request goes through rustls.
    if (!self.token) @throw[NSException exceptionWithName:@"Failed to refresh token" reason:@"Cannot refresh a token that does not exist." userInfo:@{}];
    if (!self.token.refreshToken) [[self token] load];
    if (self.token.refreshToken) {
    
        NSDictionary *body = @{
                               @"grant_type": @"refresh_token",
                               @"refresh_token": self.token.refreshToken
                               };
//    NSMutableDictionary *newBod = [NSMutableDictionary dictionaryWithDictionary:body];
//    [newBod addEntriesFromDictionary:self.token.dictionary];
    
        NSDictionary *response = [self request:self.tokenEndpoint withBody:body error:&requestError];
        
        NSLog(@"Token refresh %@", requestError ? requestError.domain : @"succeeded");
        
        if (!requestError) [self setTokenFromDictionary:response];
        
        
        if (error) *error = requestError;
    }
    return [self isLoggedIn];
}

- (FMSpotifyToken *)setTokenFromDictionary:(NSDictionary *)dictionary
{
    NSString *previousRefreshToken = self.token.refreshToken;
    self.token = [FMSpotifyToken tokenWithDictionary:dictionary];
    // Refresh responses don't always contain a new refresh token, keep the old one so we stay logged in.
    if (!self.token.refreshToken) self.token.refreshToken = previousRefreshToken;
//    if (!self.token.isValid) [self.token load];
    [self.token save];
    return self.token;
}

- (BOOL)isLoggedIn
{
    return self.token.isValid;
}

- (void)request:(NSURL *)url withOnSuccess:(void(^)(NSDictionary *))callbackSuccess onError:(void(^)(NSError *))callbackError
{
    [self request:url callback:^(NSDictionary *dictionary, NSError *error){
        if (!error) callbackSuccess(dictionary);
        else callbackError(error);
    }];
}

- (void)continueArray:(FMSpotifyContinuableArray *)continuableArray withOnSuccess:(void(^)(FMSpotifyContinuableArray *))callbackSuccess onError:(void(^)(NSError *))callbackError
{
    @try {
        NSURL *url;
        if ([continuableArray hasNext]) url = [continuableArray next];
        else if ([continuableArray count] == 0) url = [continuableArray href];
        else {
            // Everything is loaded already, fetching href again would only duplicate the first page.
            callbackSuccess(continuableArray);
            return;
        }
        NSLog(@"I will get the continuation data for: %@ sir yes sir rikesyikes u riekt", url);
        if ([url isKindOfClass:[NSString class]]) url = [NSURL URLWithString:(NSString *)url];
        if ([url isKindOfClass:[NSURL class]]) [self request:url withOnSuccess:^(NSDictionary *response){
    //        NSArray *items = [response objectForKey:@"items"];
            callbackSuccess([continuableArray addItemsFromDictionary:response]);
        } onError:callbackError];
        else callbackError([NSError errorWithDomain:@"nil_parameter" code:9000 userInfo:@{NSLocalizedDescriptionKey: @"Attempted to request null", NSLocalizedFailureReasonErrorKey: @"The client tried to fetch more data but there is no more data to be fetched. (this is a bug)"}]);
    }
    @catch (NSException *exception) {
        callbackError([self errorWithException:exception]);
    }
}

- (void)downloadTrack:(FMSpotifyTrack *)track callback:(void(^)(NSData *))callback preview:(Boolean)preview
{
    void (^downloadURL)(NSURL *) = ^(NSURL *url){
        if (!url) {
            callback(nil);
            return;
        }
        [self getDataFromURL:url withCallback:^(NSData *data){
            callback(data);
        }];
    };
    
    if (preview) {
        // The Web API no longer returns preview_url for most tracks, fall back to the metadata service.
        if (track.previewURL) downloadURL(track.previewURL);
        else [self getTrackPreviewURL:track callback:downloadURL];
    } else {
        [self getTrackDownloadURL:track callback:downloadURL];
    }
}

- (void)downloadTrack:(FMSpotifyTrack *)track callback:(void(^)(NSData *))callback
{
    [self downloadTrack:track callback:callback preview:true];
}

- (NSURL *)getTrackMetaURL:(FMSpotifyTrack *)track
{
    if (!track.identifier) return nil;
    FMBase62Decoder *decoder = [FMBase62Decoder decoderWithString:track.identifier];
    NSString *trackId = [decoder toHex];
    NSString *metaURL = [NSString stringWithFormat:@"https://spclient.wg.spotify.com/metadata/4/track/%@?market=from_token", trackId];
    return [NSURL URLWithString:metaURL];
}

- (NSURL *)previewURLFromMetadata:(NSDictionary *)response
{
    NSArray *previews = [response objectForKey:@"preview"];
    if (![previews isKindOfClass:[NSArray class]] || ![previews count]) return nil;
    NSDictionary *fileFormat = [previews objectAtIndex:0];
    if (![fileFormat isKindOfClass:[NSDictionary class]]) return nil;
    NSString *fileId = [fileFormat objectForKey:@"file_id"];
    if (![fileId isKindOfClass:[NSString class]]) return nil;
    
    NSLog(@"preview file ID: %@ with format: %@", fileId, [fileFormat objectForKey:@"format"]);
    return [NSURL URLWithString:[@"https://p.scdn.co/mp3-preview/" stringByAppendingString:fileId]];
}

- (void)getTrackPreviewURL:(FMSpotifyTrack *)track callback:(void(^)(NSURL *))callback
{
    NSURL *metaURL = [self getTrackMetaURL:track];
    if (!metaURL) {
        callback(nil);
        return;
    }
    
    [self request:metaURL callback:^(NSDictionary *response, NSError *error){
        callback(error ? nil : [self previewURLFromMetadata:response]);
    }];
}

- (void)getTrackDownloadURL:(FMSpotifyTrack *)track callback:(void(^)(NSURL *))callback
{
    NSURL *metaURL = [self getTrackMetaURL:track];
    if (!metaURL) {
        callback(nil);
        return;
    }
    
    [self request:metaURL callback:^(NSDictionary *response, NSError *error){
        NSArray *fileFormats = [response objectForKey:@"file"];
        NSString *fileId;
        
        if ([fileFormats isKindOfClass:[NSArray class]]) for (NSDictionary *fileFormat in fileFormats) {
            NSString *formatFileId = [fileFormat objectForKey:@"file_id"];
            NSString *formatFormat = [fileFormat objectForKey:@"format"];
            
            NSLog(@"Found format: %@ which has file ID: %@", formatFormat, formatFileId);
            
            if ([formatFormat isEqual:@"MP3_96"]) {
                fileId = formatFileId;
                break;
            }
        }
        
        if (!fileId) {
            NSLog(@"This track doesn't have a supported codec! Loading preview of the song...");
            callback([self previewURLFromMetadata:response]);
            return;
        }
        
        NSString *storageURL = @"https://gew4-spclient.spotify.com/storage-resolve/v2/files/audio/interactive/10/";
        NSString *fullStorageURL = [[storageURL stringByAppendingString:fileId] stringByAppendingString:@"?product=9&alt=json"];
        
        [self request:[NSURL URLWithString:fullStorageURL] callback:^(NSDictionary *storageResponse, NSError *storageError){
            NSArray *cdns = [storageResponse objectForKey:@"cdnurl"];
            NSString *cdn = [cdns isKindOfClass:[NSArray class]] && [cdns count] ? [cdns objectAtIndex:0] : nil;
            
            NSLog(@"CDN download url: %@", cdn);
            
            if ([cdn isKindOfClass:[NSString class]]) callback([NSURL URLWithString:cdn]);
            else callback([self previewURLFromMetadata:response]);
        }];
    }];
}

- (void)search:(NSString *)query withOnSuccess:(void(^)(FMSpotifyTrackArray *tracks))callbackSuccess onError:(void(^)(NSError *error))callbackError
{
    NSURL *searchEndpoint = [self.apiBaseAddress URLByAppendingPathComponent:@"search"];
    
//    NSArray *types = @[@"album", @"artist", @"playlist", @"track", @"show", @"episode", @"audiobook"];
    FMMutableURLQueryDictionary *queryDictionary = [FMMutableURLQueryDictionary urlQueryDictionaryWithDictionary:@{@"q":query, @"type": @"track"}];
    
    NSURL *searchURL = [queryDictionary addToURL:searchEndpoint];
    NSLog(@"Searching query: %@", searchURL);
    
    [self request:searchURL callback:^(NSDictionary *result, NSError *error){
        if (!error) {
            callbackSuccess([FMSpotifyTrackArray trackArrayWithDictionary:result]);
        } else callbackError(error);
    }];

}

- (void)connection:(NSURLConnection *)connection willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        NSLog(@"Ignoring SUCKSL");
        SecTrustRef trust = challenge.protectionSpace.serverTrust;
        NSURLCredential *cred;
        cred = [NSURLCredential credentialForTrust:trust];
        [challenge.sender useCredential:cred forAuthenticationChallenge:challenge];
    }
}

- (NSException *)exceptionWithError:(NSError *)error
{
    return [NSException exceptionWithName:error.domain reason:error.localizedFailureReason userInfo:@{}];
}

- (NSError *)errorWithException:(NSException *)exception
{
    return [NSError errorWithDomain:[exception name] code:1000 userInfo:@{NSLocalizedFailureReasonErrorKey: [exception reason], NSLocalizedDescriptionKey: [exception description]}];
}

+ (FMSpotifyClient *)spotifyClient
{
    return [[FMSpotifyClient alloc] init];
}

@end
