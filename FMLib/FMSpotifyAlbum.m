//
//  FMSpotifyAlbum.m
//  Retrofy
//
//  Created by Lasse Lauwerys on 2/07/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import "FMSpotifyAlbum.h"

@implementation FMSpotifyAlbum

- (id)initWithDictionary:(NSDictionary *)dictionary
{
    self = [super init];
    if (self) {
        if (![dictionary isKindOfClass:[NSDictionary class]]) return self;
        NSString *name = [dictionary objectForKey:@"name"];
        if ([name isKindOfClass:[NSString class]]) [self setName:name];
        NSString *href = [dictionary objectForKey:@"href"];
        if ([href isKindOfClass:[NSString class]]) [self setHref:[NSURL URLWithString:href]];
        NSArray *images = [dictionary objectForKey:@"images"];
        NSDictionary *image = [images isKindOfClass:[NSArray class]] && [images count] ? [images objectAtIndex:0] : nil;
        NSString *imageURL = [image isKindOfClass:[NSDictionary class]] ? [image objectForKey:@"url"] : nil;
        if ([imageURL isKindOfClass:[NSString class]]) [self setImageURL:[NSURL URLWithString:imageURL]];
    }
    return self;
}

+ (FMSpotifyAlbum *)albumFromDictionary:(NSDictionary *const)dictionary
{
    return [[FMSpotifyAlbum alloc] initWithDictionary:dictionary];
}

@end
