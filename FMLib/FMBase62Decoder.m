//
//  FMBase62Decoder.m
//  Retrofy
//
//  Created by Lasse Lauwerys on 03/12/24.
//  Copyright (c) 2024 Lasse Lauwerys. All rights reserved.
//

#import "FMBase62Decoder.h"

@implementation FMBase62Decoder

- (id)init
{
    self = [super init];
    if (self) {
        [self setCharset:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"];
    }
    return self;
}

- (NSString *)toHex
{
    // Spotify IDs are 128 bit numbers, which doesn't fit in a UInt64. Decode into 16 big endian bytes instead.
    uint8_t bytes[16] = {0};
    NSString *string = [self string];
    
    for (NSUInteger i = 0; i < [string length]; i++) {
        NSRange range = [[self charset] rangeOfString:[string substringWithRange:NSMakeRange(i, 1)]];
        if (range.location == NSNotFound) return nil;
        
        UInt32 carry = (UInt32)range.location;
        for (int j = 15; j >= 0; j--) {
            carry += bytes[j] * 62;
            bytes[j] = carry & 0xFF;
            carry >>= 8;
        }
    }
    
    NSMutableString *hexString = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) [hexString appendFormat:@"%02x", bytes[i]];
    return hexString;
}

- (UInt64)decodeBase62String:(NSString *)base62String
{
    UInt64 num = 0, len = [base62String length];

    for (int i = 0; i < len; i++)
    {
        NSRange range = [[self charset] rangeOfString:[base62String substringWithRange:NSMakeRange(len - i - 1, 1)]];
        num += range.location * pow(62, i);
    }

    return num;
}

+ (FMBase62Decoder *)decoder
{
    return [[FMBase62Decoder alloc] init];
}

+ (FMBase62Decoder *)decoderWithString:(NSString *)string
{
    FMBase62Decoder *decoder = [FMBase62Decoder decoder];
    [decoder setString:string];
    return decoder;
}

@end
