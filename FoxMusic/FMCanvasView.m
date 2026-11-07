//
//  FMCanvasView.m
//  Retrofy
//
//  Spotify's Canvas: the short looping clip some tracks show instead of their cover. Stays hidden, showing the
//  cover behind it, until a clip is ready, and for clips this device can't decode.
//

#import "FMCanvasView.h"

#import <AVFoundation/AVFoundation.h>

static void *FMCanvasItemStatusContext = &FMCanvasItemStatusContext;

@interface FMCanvasView ()
{
    AVPlayer *_player;
    AVPlayerItem *_item;
}
@end

@implementation FMCanvasView

+ (Class)layerClass
{
    return [AVPlayerLayer class];
}

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.hidden = YES;
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        [(AVPlayerLayer *)self.layer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
    }
    return self;
}

- (void)dealloc
{
    [self stopObservingItem];
}

- (void)stopObservingItem
{
    if (!_item) return;
    [_item removeObserver:self forKeyPath:@"status" context:FMCanvasItemStatusContext];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:_item];
    _item = nil;
}

- (void)showVideoAtURL:(NSURL *)url
{
    self.hidden = YES;
    [_player pause];
    [self stopObservingItem];
    [(AVPlayerLayer *)self.layer setPlayer:nil];
    _player = nil;
    if (!url) return;

    _item = [AVPlayerItem playerItemWithURL:url];
    [_item addObserver:self forKeyPath:@"status" options:0 context:FMCanvasItemStatusContext];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemDidEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:_item];

    _player = [AVPlayer playerWithPlayerItem:_item];
    _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    [(AVPlayerLayer *)self.layer setPlayer:_player];
}

- (void)setPlaying:(BOOL)playing
{
    _playing = playing;
    if (playing) [_player play];
    else [_player pause];
}

- (void)itemDidEnd:(NSNotification *)notification
{
    [_player seekToTime:kCMTimeZero];
    if (self.playing) [_player play];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context != FMCanvasItemStatusContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (object != _item) return;
        if (_item.status == AVPlayerItemStatusReadyToPlay) {
            self.hidden = NO;
            if (self.playing) [_player play];
            if (self.showingHandler) self.showingHandler(YES);
        } else if (_item.status == AVPlayerItemStatusFailed) {
            NSLog(@"Couldn't play the Canvas: %@", _item.error.localizedDescription);
            [self showVideoAtURL:nil];
            if (self.showingHandler) self.showingHandler(NO);
        }
    });
}

@end
