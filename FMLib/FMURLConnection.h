//
//  FMURLConnection.h
//  Retrofy
//
//  Created by Lasse Lauwerys on 28/11/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "FMURLConnectionDelegate.h"
#import "FMMutableURLQueryDictionary.h"

#ifdef FM_IOS4
// iOS 4 stops at TLS 1.0, which Spotify's servers refuse, so all requests go through the Rust library's
// rustls. Calls back on the main thread, with nil when the request failed.
void FMSendRustlsRequest(NSString *method, NSURL *url, NSString *authorization, void (^callback)(NSData *data));
#endif

@interface FMURLConnection : NSObject

@property FMURLConnectionDelegate *urlConnectionDelegate;

- (void)getDataFromURL:(NSURL *)url withCallback:(void (^)(NSData *))callback;
- (void)getDataFromURL:(NSURL *)url withCallback:(void (^)(NSData *))callback andHeaders:(NSDictionary *)headers;
- (void)getDataFromURL:(NSURL *)url withCallback:(void (^)(NSData *))callback andQuery:(NSDictionary *)query;
- (void)getDataFromURL:(NSURL *)url withCallback:(void (^)(NSData *))callback andQuery:(NSDictionary *)query andHeaders:(NSDictionary *)headers;


+ (FMURLConnection *)urlConnection;

@end
