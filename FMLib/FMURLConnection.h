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

#ifdef FM_LIBRESPOT
// Through the Rust library's rustls. iOS 4 stops at TLS 1.0, which Spotify's servers refuse, so there all
// requests go this way. Calls back on the main thread, with nil when the request failed.
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
