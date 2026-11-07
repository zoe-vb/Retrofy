//
//  main.m
//  Slint Test
//
//  One screen: test.mp4 looping in an AVPlayerLayer, with the Slint UI in a transparent OpenGL ES 2 layer on top.
//

#import <AVFoundation/AVFoundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#import "../fmslint.h"

static EAGLContext *FMContext;
static GLuint FMColourBuffer;

static void FMPresent(void)
{
    // femtovg unbinds renderbuffers when it makes a shadow's stencil.
    glBindRenderbuffer(GL_RENDERBUFFER, FMColourBuffer);
    [FMContext presentRenderbuffer:GL_RENDERBUFFER];
}

static void FMLog(const char *message)
{
    NSLog(@"Slint: %s", message);
}

@interface FMVideoView : UIView
@end

@implementation FMVideoView
+ (Class)layerClass
{
    return [AVPlayerLayer class];
}
@end

@interface FMGLView : UIView
{
    GLuint _framebuffer, _stencil;
    CADisplayLink *_link;
}
@end

@implementation FMGLView

+ (Class)layerClass
{
    return [CAEAGLLayer class];
}

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.multipleTouchEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentScaleFactor = [UIScreen mainScreen].scale;
        CAEAGLLayer *layer = (CAEAGLLayer *)self.layer;
        layer.opaque = NO;
        layer.drawableProperties = @{kEAGLDrawablePropertyRetainedBacking: @NO,
                                     kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8};
    }
    return self;
}

- (void)start
{
    FMContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    [EAGLContext setCurrentContext:FMContext];

    glGenFramebuffers(1, &_framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);

    glGenRenderbuffers(1, &FMColourBuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, FMColourBuffer);
    [FMContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)self.layer];
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, FMColourBuffer);

    GLint width = 0, height = 0;
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &width);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &height);

    glGenRenderbuffers(1, &_stencil);
    glBindRenderbuffer(GL_RENDERBUFFER, _stencil);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8_OES, width, height);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _stencil);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, _stencil);

    NSLog(@"Slint: %s, %s, %dx%d, framebuffer status %x", glGetString(GL_VERSION), glGetString(GL_RENDERER), width, height, glCheckFramebufferStatus(GL_FRAMEBUFFER));

    if (fm_ui_start(_framebuffer, width, height, self.contentScaleFactor, FMPresent, FMLog) != 0) return;

    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)tick
{
    [EAGLContext setCurrentContext:FMContext];
    fm_ui_tick();
}

- (void)touch:(NSSet *)touches phase:(int)phase
{
    CGPoint point = [[touches anyObject] locationInView:self];
    fm_ui_touch(phase, point.x, point.y);
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event { [self touch:touches phase:0]; }
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event { [self touch:touches phase:1]; }
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event { [self touch:touches phase:2]; }
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event { [self touch:touches phase:3]; }

@end

@interface FMTestDelegate : UIResponder <UIApplicationDelegate>
{
    UIWindow *_window;
    AVPlayer *_player;
}
@end

@implementation FMTestDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    CGRect bounds = [UIScreen mainScreen].bounds;
    _window = [[UIWindow alloc] initWithFrame:bounds];
    _window.backgroundColor = [UIColor blackColor];

    UIViewController *controller = [[UIViewController alloc] init];
    controller.view = [[UIView alloc] initWithFrame:bounds];
    controller.view.backgroundColor = [UIColor blackColor];

    FMVideoView *video = [[FMVideoView alloc] initWithFrame:bounds];
    NSURL *url = [[NSBundle mainBundle] URLForResource:@"test" withExtension:@"mp4"];
    _player = [AVPlayer playerWithURL:url];
    _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    _player.muted = YES;
    AVPlayerLayer *layer = (AVPlayerLayer *)video.layer;
    layer.player = _player;
    layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(loop:) name:AVPlayerItemDidPlayToEndTimeNotification object:_player.currentItem];
    [_player play];
    [controller.view addSubview:video];

    FMGLView *gl = [[FMGLView alloc] initWithFrame:bounds];
    [controller.view addSubview:gl];

    _window.rootViewController = controller;
    [_window makeKeyAndVisible];
    [gl start];
    return YES;
}

- (void)loop:(NSNotification *)notification
{
    [_player seekToTime:kCMTimeZero];
    [_player play];
}

@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([FMTestDelegate class]));
    }
}
