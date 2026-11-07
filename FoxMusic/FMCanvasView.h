//
//  FMCanvasView.h
//  Retrofy
//
//  Spotify's Canvas: the short looping clip some tracks show instead of their cover. Stays hidden, showing the
//  cover behind it, until a clip is ready, and for clips this device can't decode.
//

#import <UIKit/UIKit.h>

@interface FMCanvasView : UIView

// nil goes back to the cover.
- (void)showVideoAtURL:(NSURL *)url;

@property (nonatomic) BOOL playing;

@end
