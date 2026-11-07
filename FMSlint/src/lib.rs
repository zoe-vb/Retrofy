//! Slint on iOS 6: a Platform with no event loop of its own, as UIKit has that. The app's CADisplayLink calls
//! `fm_ui_tick` and its touches arrive through `fm_ui_touch`.

mod compat;

use std::cell::{Cell, RefCell};
use std::ffi::{c_char, c_void, CStr, CString};
use std::num::NonZeroU32;
use std::rc::{Rc, Weak};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Mutex;
use std::time::Instant;

use slint::platform::femtovg_renderer::{FemtoVGRenderer, OpenGLInterface};
use slint::platform::{
    update_timers_and_animations, EventLoopProxy, Platform, PointerEventButton, Renderer, WindowAdapter, WindowEvent,
};
use slint::{ComponentHandle, LogicalPosition, PhysicalSize, PlatformError, Window};

slint::include_modules!();

type BoxedError = Box<dyn std::error::Error + Send + Sync>;
type Job = Box<dyn FnOnce() + Send>;

static SCREEN_FBO: AtomicU32 = AtomicU32::new(0);
static JOBS: Mutex<Vec<Job>> = Mutex::new(Vec::new());
static mut LOG: Option<extern "C" fn(*const c_char)> = None;

const RTLD_DEFAULT: *mut c_void = -2isize as *mut c_void;

extern "C" {
    fn dlsym(handle: *mut c_void, name: *const c_char) -> *const c_void;
    fn glBindFramebuffer(target: u32, framebuffer: u32);
}

fn log(message: &str) {
    if let (Some(log), Ok(message)) = (unsafe { LOG }, CString::new(message)) {
        log(message.as_ptr());
    }
}

/// iOS has no framebuffer 0, the screen is a framebuffer of the app's. femtovg binds 0 for the screen, so its
/// glBindFramebuffer is this one.
extern "C" fn bind_framebuffer(target: u32, framebuffer: u32) {
    let framebuffer = if framebuffer == 0 { SCREEN_FBO.load(Ordering::Relaxed) } else { framebuffer };
    unsafe { glBindFramebuffer(target, framebuffer) }
}

struct AppGL {
    present: extern "C" fn(),
}

unsafe impl OpenGLInterface for AppGL {
    fn ensure_current(&self) -> Result<(), BoxedError> {
        Ok(())
    }

    fn swap_buffers(&self) -> Result<(), BoxedError> {
        (self.present)();
        Ok(())
    }

    fn resize(&self, _width: NonZeroU32, _height: NonZeroU32) -> Result<(), BoxedError> {
        Ok(())
    }

    fn get_proc_address(&self, name: &CStr) -> *const c_void {
        // On Apple targets glow asks for desktop OpenGL's vertex array names, OpenGL ES has the OES ones.
        let name = match name.to_bytes() {
            b"glBindFramebuffer" => return bind_framebuffer as *const c_void,
            b"glGenVertexArraysAPPLE" => c"glGenVertexArraysOES",
            b"glBindVertexArrayAPPLE" => c"glBindVertexArrayOES",
            b"glDeleteVertexArraysAPPLE" => c"glDeleteVertexArraysOES",
            _ => name,
        };
        unsafe { dlsym(RTLD_DEFAULT, name.as_ptr()) }
    }
}

struct Adapter {
    window: Window,
    renderer: FemtoVGRenderer,
    size: Cell<PhysicalSize>,
    needs_redraw: Cell<bool>,
}

impl WindowAdapter for Adapter {
    fn window(&self) -> &Window {
        &self.window
    }

    fn size(&self) -> PhysicalSize {
        self.size.get()
    }

    fn renderer(&self) -> &dyn Renderer {
        &self.renderer
    }

    fn request_redraw(&self) {
        self.needs_redraw.set(true);
    }
}

struct Proxy;

impl EventLoopProxy for Proxy {
    fn quit_event_loop(&self) -> Result<(), slint::EventLoopError> {
        Ok(())
    }

    fn invoke_from_event_loop(&self, event: Job) -> Result<(), slint::EventLoopError> {
        JOBS.lock().unwrap().push(event);
        Ok(())
    }
}

struct AppPlatform {
    present: extern "C" fn(),
    adapter: Rc<RefCell<Option<Rc<Adapter>>>>,
}

impl Platform for AppPlatform {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, PlatformError> {
        let renderer = FemtoVGRenderer::new(AppGL { present: self.present })?;
        let adapter = Rc::<Adapter>::new_cyclic(|weak: &Weak<Adapter>| Adapter {
            window: Window::new(weak.clone() as Weak<dyn WindowAdapter>),
            renderer,
            size: Cell::new(PhysicalSize::new(0, 0)),
            needs_redraw: Cell::new(true),
        });
        *self.adapter.borrow_mut() = Some(adapter.clone());
        Ok(adapter)
    }

    fn new_event_loop_proxy(&self) -> Option<Box<dyn EventLoopProxy>> {
        Some(Box::new(Proxy))
    }
}

struct Session {
    adapter: Rc<Adapter>,
    ui: NowPlaying,
    frames: Cell<u32>,
    since: Cell<Instant>,
}

thread_local! {
    static SESSION: RefCell<Option<Session>> = const { RefCell::new(None) };
}

fn start(width: u32, height: u32, scale: f32, present: extern "C" fn()) -> Result<(), BoxedError> {
    let adapter = Rc::new(RefCell::new(None));
    slint::platform::set_platform(Box::new(AppPlatform { present, adapter: adapter.clone() }))?;

    let ui = NowPlaying::new()?;
    let adapter = adapter.borrow().clone().ok_or("Slint made no window")?;

    let size = PhysicalSize::new(width, height);
    adapter.size.set(size);
    adapter.window.dispatch_event(WindowEvent::ScaleFactorChanged { scale_factor: scale });
    adapter.window.dispatch_event(WindowEvent::Resized { size: size.to_logical(scale) });
    ui.show()?;

    SESSION.with(|session| {
        *session.borrow_mut() = Some(Session {
            adapter,
            ui,
            frames: Cell::new(0),
            since: Cell::new(Instant::now()),
        })
    });
    Ok(())
}

#[no_mangle]
pub extern "C" fn fm_ui_start(
    fbo: u32,
    width: u32,
    height: u32,
    scale: f32,
    present: extern "C" fn(),
    log_fn: extern "C" fn(*const c_char),
) -> i32 {
    unsafe { LOG = Some(log_fn) };
    std::panic::set_hook(Box::new(|info| log(&format!("Panic: {info}"))));
    SCREEN_FBO.store(fbo, Ordering::Relaxed);
    match start(width, height, scale, present) {
        Ok(()) => 0,
        Err(error) => {
            log(&format!("Couldn't start Slint: {error}"));
            1
        }
    }
}

#[no_mangle]
pub extern "C" fn fm_ui_tick() {
    let jobs = std::mem::take(&mut *JOBS.lock().unwrap());
    for job in jobs {
        job();
    }
    update_timers_and_animations();

    SESSION.with(|session| {
        let session = session.borrow();
        let Some(session) = session.as_ref() else { return };
        let adapter = &session.adapter;
        if !adapter.needs_redraw.get() && !adapter.window.has_active_animations() {
            return;
        }
        adapter.needs_redraw.set(false);
        let start = Instant::now();
        if let Err(error) = adapter.renderer.render() {
            log(&format!("Couldn't render: {error}"));
        }
        let cost = start.elapsed();

        let frames = session.frames.get() + 1;
        let elapsed = session.since.get().elapsed().as_secs_f32();
        if elapsed >= 1.0 {
            let stats = format!("{:.0} fps, {:.1} ms", frames as f32 / elapsed, cost.as_secs_f32() * 1000.0);
            log(&stats);
            session.ui.set_stats(stats.into());
            session.frames.set(0);
            session.since.set(Instant::now());
        } else {
            session.frames.set(frames);
        }
    });
}

#[no_mangle]
pub extern "C" fn fm_ui_touch(phase: i32, x: f32, y: f32) {
    SESSION.with(|session| {
        let session = session.borrow();
        let Some(session) = session.as_ref() else { return };
        let window = &session.adapter.window;
        let position = LogicalPosition::new(x, y);
        let button = PointerEventButton::Left;
        match phase {
            0 => {
                window.dispatch_event(WindowEvent::PointerMoved { position });
                window.dispatch_event(WindowEvent::PointerPressed { position, button });
            }
            1 => window.dispatch_event(WindowEvent::PointerMoved { position }),
            _ => {
                window.dispatch_event(WindowEvent::PointerReleased { position, button });
                window.dispatch_event(WindowEvent::PointerExited);
            }
        }
    });
}
