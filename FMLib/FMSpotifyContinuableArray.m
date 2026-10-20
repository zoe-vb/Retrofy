//
//  FMSpotifyContinuable.m
//  FoxMusic
//
//  Created by Lasse Lauwerys on 2/07/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import "FMSpotifyContinuableArray.h"

@implementation FMSpotifyContinuableArray

- (id)initWithDictionary:(NSDictionary *)dictionary
{
    self = [super init];
    if (self) {
        //[self setURLsFromDictionary:dictionary];
        
        if (![dictionary isKindOfClass:[NSDictionary class]]) dictionary = nil;
        NSString *previous = [dictionary objectForKey:@"previous"];
        if ([previous isKindOfClass:[NSString class]] && [previous length]) self.previous = [NSURL URLWithString:previous];
        self.total = [dictionary objectForKey:@"total"];
        self.offset = [dictionary objectForKey:@"offset"];
        self.items = [NSMutableArray array];
        
        [self addItemsFromDictionary:dictionary];
    }
    return self;
}
// extend with dictionary
- (FMSpotifyContinuableArray *)addItemsFromDictionary:(NSDictionary *)dictionary
{
    [self setURLsFromDictionary:dictionary];
    
    if (![dictionary isKindOfClass:[NSDictionary class]]) return self;
    NSArray *items = [dictionary objectForKey:@"items"];
    if ([items isKindOfClass:[NSArray class]]) [self.items addObjectsFromArray:items];
    return self;
}

- (FMSpotifyContinuableArray *)addItems:(FMSpotifyContinuableArray *)continuableArray
{
//    [self setURLsFromDictionary:dictionary];
    
//    NSArray *items = [dictionary objectForKey:@"items"];
//    if ([items isKindOfClass:[NSArray class]])
    // Continuing an array adds to the same object, don't add its items to itself again.
    if (continuableArray == self) return self;
    [self.items addObjectsFromArray:[continuableArray items]];
    return self;
}

- (void)setURLsFromDictionary:(NSDictionary *)dictionary
{
    if (![dictionary isKindOfClass:[NSDictionary class]]) return;
    NSString *href = [dictionary objectForKey:@"href"];
    if ([href isKindOfClass:[NSString class]]) self.href = [NSURL URLWithString:href];
    NSNumber *total = [dictionary objectForKey:@"total"];
    if ([total isKindOfClass:[NSNumber class]]) self.total = total;
    NSString *next = [dictionary objectForKey:@"next"];
    if ([next isKindOfClass:[NSString class]] && [next length]) self.next = [NSURL URLWithString:next];
    else self.next = nil;
}

- (NSUInteger)count
{
    return self.items.count;
}

- (id)itemAtIndex:(NSUInteger)index
{
    return index < [[self items] count] ? [[self items] objectAtIndex:index] : nil;
}

- (BOOL)hasNext
{
    return [self next] != nil && [[self next] isKindOfClass:[NSURL class]];
}

- (BOOL)isComplete
{
    return [[self total] unsignedIntegerValue] <= [self count];
}

- (BOOL)hasPrevious
{
    return self.previous != nil;
}

@end
