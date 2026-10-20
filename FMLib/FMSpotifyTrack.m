//
//  FMSpotifyTrack.m
//  Retrofy
//
//  Created by Lasse Lauwerys on 2/07/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import "FMSpotifyTrack.h"

@implementation FMSpotifyTrack

- (id)initWithDictionary:(NSDictionary *)dictionary
{
    self = [super init];
    if (self) {
        [self setName:[dictionary objectForKey:@"name"]];
        [self setIdentifier:[dictionary objectForKey:@"id"]];
        NSNumber *duration = [dictionary objectForKey:@"duration_ms"];
        if ([duration isKindOfClass:[NSNumber class]]) [self setDuration:[duration doubleValue] / 1000];
        [self setAlbum:[FMSpotifyAlbum albumFromDictionary:[dictionary objectForKey:@"album"]]];

        NSArray *artists = [dictionary objectForKey:@"artists"];
        NSMutableArray *artistNames = [NSMutableArray array];
        if ([artists isKindOfClass:[NSArray class]]) for (NSDictionary *artist in artists) {
            NSString *name = [artist isKindOfClass:[NSDictionary class]] ? [artist objectForKey:@"name"] : nil;
            if ([name isKindOfClass:[NSString class]] && [name length]) [artistNames addObject:name];
        }
        [self setArtistNames:artistNames];
        
        @try {
            NSString *previewURL = [dictionary objectForKey:@"preview_url"];
            if ([previewURL isKindOfClass:[NSString class]]) [self setPreviewURL:[NSURL URLWithString:previewURL]];
        }
        @catch (NSException *exception) {
            NSLog(@"Failed to load preview URL");
        }
        
    }
    return self;
}

- (NSString *)artistName
{
    return [self.artistNames count] ? [self.artistNames componentsJoinedByString:@", "] : nil;
}

- (NSUInteger)hash
{
    return [[self identifier] hash];
}

- (BOOL)isEqual:(id)object
{
    return [object isKindOfClass:[FMSpotifyTrack class]] && [[self identifier] isEqualToString:[object identifier]];
}

+ (FMSpotifyTrack *)trackFromDictionary:(NSDictionary *const)dictionary
{
    return [[FMSpotifyTrack alloc] initWithDictionary:dictionary];
}

@end
