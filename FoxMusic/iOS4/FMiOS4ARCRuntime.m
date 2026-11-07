//
//  FMiOS4ARCRuntime.m
//  Retrofy
//
//  ARC's runtime functions, which libobjc only has since iOS 5. Apple's libarclite provides them for older
//  systems, but isn't linked here because of -nodefaultlibs (see build.sh). Compiled without ARC.
//

#import <Foundation/Foundation.h>
#import <Block.h>

id objc_retain(id object)
{
    return [object retain];
}

void objc_release(id object)
{
    [object release];
}

id objc_autorelease(id object)
{
    return [object autorelease];
}

id objc_retainAutorelease(id object)
{
    return [[object retain] autorelease];
}

id objc_autoreleaseReturnValue(id object)
{
    return [object autorelease];
}

id objc_retainAutoreleaseReturnValue(id object)
{
    return [[object retain] autorelease];
}

id objc_retainAutoreleasedReturnValue(id object)
{
    return [object retain];
}

void objc_storeStrong(id *location, id object)
{
    id previous = *location;
    [object retain];
    *location = object;
    [previous release];
}

id objc_retainBlock(id block)
{
    return Block_copy(block);
}

void *objc_autoreleasePoolPush(void)
{
    return [[NSAutoreleasePool alloc] init];
}

void objc_autoreleasePoolPop(void *pool)
{
    [(NSAutoreleasePool *)pool drain];
}
