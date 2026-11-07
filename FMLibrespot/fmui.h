//
//  fmui.h
//  Retrofy
//
//  The Slint UI on the app's OpenGL ES 2 framebuffer. Everything here is called on the main thread, with the
//  EAGLContext current for fm_ui_start and fm_ui_tick.
//

#ifndef FMUI_H
#define FMUI_H

#include <stdint.h>

typedef void (*fm_ui_present_fn)(void);
typedef void (*fm_ui_log_fn)(const char *message);
// Something the user did on a screen. See handleAction: in FMInterface.m.
typedef void (*fm_ui_action_fn)(const char *name, int index, const char *text);

// fbo is the framebuffer of the CAEAGLLayer, with a stencil attachment. Sizes are pixels, scale is the screen's.
// Returns 0 on success.
int fm_ui_start(uint32_t fbo, uint32_t width, uint32_t height, float scale, fm_ui_present_fn present, fm_ui_log_fn log, fm_ui_action_fn action);

// Once a frame, from a CADisplayLink. Calls present when there's a new frame on the framebuffer.
void fm_ui_tick(void);

// Phase: 0 down, 1 moved, 2 up, 3 cancelled. Position in points.
void fm_ui_touch(int phase, float x, float y);

// New contents for part of the UI, as JSON. The kinds are in send() in src/ui.rs.
void fm_ui_send(const char *kind, const char *json);

// Where playback is, in seconds, and the current line of the lyrics or -1.
void fm_ui_progress(float position, float duration, int lyric_line);

// An opaque picture for every tile, or the Now Playing cover, with this key. 4 bytes per pixel, RGBA.
void fm_ui_image(const char *key, const uint8_t *rgba, uint32_t width, uint32_t height);

#endif
