//
//  fmslint.h
//  Retrofy
//
//  Runs a Slint UI on the app's own OpenGL ES 2 framebuffer. Everything here is called on the main thread with
//  the EAGLContext current.
//

#include <stdint.h>

typedef void (*fm_ui_present_fn)(void);
typedef void (*fm_ui_log_fn)(const char *message);

// fbo is the framebuffer of the CAEAGLLayer, with a stencil attachment. Sizes are pixels, scale is the screen's.
// Returns 0 on success.
int fm_ui_start(uint32_t fbo, uint32_t width, uint32_t height, float scale, fm_ui_present_fn present, fm_ui_log_fn log);

// Once a frame, from a CADisplayLink. Calls present when there's a new frame on the framebuffer.
void fm_ui_tick(void);

// Phase: 0 down, 1 moved, 2 up, 3 cancelled. Position in points.
void fm_ui_touch(int phase, float x, float y);
