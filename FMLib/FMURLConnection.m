//
//  FMURLConnection.m
//  Retrofy
//
//  Created by Lasse Lauwerys on 28/11/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import "FMURLConnection.h"

#ifdef FM_IOS4
#import "fmlibrespot.h"

// Every request does a full TLS handshake, more than a few at once is too much for an armv6 CPU.
static const long FMRustlsMaximumRequests = 3;

void FMSendRustlsRequest(NSString *method, NSURL *url, NSString *authorization, void (^callback)(NSData *data))
{
    static dispatch_semaphore_t requestSlots;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        requestSlots = dispatch_semaphore_create(FMRustlsMaximumRequests);
    });

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        dispatch_semaphore_wait(requestSlots, DISPATCH_TIME_FOREVER);

        int status = 0;
        uint8_t *body = NULL;
        size_t bodyLength = 0;
        char *error = NULL;
        NSData *data = nil;
        if (fm_https_request([method UTF8String], [[url absoluteString] UTF8String], NULL, [authorization UTF8String], NULL, 0, &status, &body, &bodyLength, &error)) {
            NSLog(@"%@ %@ -> HTTP %d", method, url, status);
            data = [NSData dataWithBytes:body length:bodyLength];
            fm_librespot_free_buffer(body, bodyLength);
        } else {
            NSLog(@"%@ %@ failed: %s", method, url, error);
            fm_librespot_free_string(error);
        }

        dispatch_semaphore_signal(requestSlots);
        dispatch_async(dispatch_get_main_queue(), ^{
            callback(data);
        });
    });
}
#endif

@implementation FMURLConnection

- (id)init
{
    self = [super init];
    if (self) {
        [self setUrlConnectionDelegate:[FMURLConnectionDelegate urlConnectionDelegate]];
    }
    return self;
}

- (void)getDataFromURL:(NSURL *)url withCallback:(void (^)(NSData *))callback
{
    [self getDataFromURL:url withCallback:callback andQuery:nil andHeaders:nil];
}

- (void)getDataFromURL:(NSURL *)url withCallback:(void (^)(NSData *))callback andHeaders:(NSDictionary *)headers
{
    [self getDataFromURL:url withCallback:callback andQuery:nil andHeaders:headers];
}

- (void)getDataFromURL:(NSURL *)url withCallback:(void (^)(NSData *))callback andQuery:(NSDictionary *)query
{
    [self getDataFromURL:url withCallback:callback andQuery:query andHeaders:nil];
}

- (void)getDataFromURL:(NSURL *)url withCallback:(void (^)(NSData *))callback andQuery:(NSDictionary *)query andHeaders:(NSDictionary *)headers
{
    if (query) url = [[FMMutableURLQueryDictionary urlQueryDictionaryWithDictionary:query] addToURL:url];
#ifdef FM_IOS4
    FMSendRustlsRequest(@"GET", url, [headers objectForKey:@"Authorization"], callback);
    return;
#endif
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    if (headers)
        for (NSString *headerField in headers)
            [request addValue:[headers objectForKey:headerField] forHTTPHeaderField:headerField];
    FMURLConnectionDelegate *delegate = [FMURLConnectionDelegate urlConnectionControllerWithCallback:callback];
    NSURLConnection *urlConnection = [[NSURLConnection alloc] initWithRequest:request delegate:delegate];
    [urlConnection start];
}

+ (FMURLConnection *)urlConnection
{
    return [[FMURLConnection alloc] init];
}

@end
