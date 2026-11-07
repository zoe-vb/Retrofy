//
//  FMInterface.h
//  Retrofy
//
//  The app's interface: the Slint screens (FMLibrespot/ui/app.slint) in an OpenGL ES 2 layer, on top of the Canvas
//  clip. This hands them what to show and acts on what the user does, the Spotify and playback code stays as it was.
//

#import <UIKit/UIKit.h>

@interface FMInterface : NSObject <UITextFieldDelegate, UIAlertViewDelegate>

+ (FMInterface *)sharedInterface;

// Makes the app delegate's window, and starts showing the screens.
- (void)show;

@end
