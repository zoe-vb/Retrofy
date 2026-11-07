//! The UI: Slint on iOS 6. UIKit keeps the event loop, so this Platform has none of its own: FMInterface's
//! CADisplayLink calls `fm_ui_tick`, and touches arrive through `fm_ui_touch`. The screens are in `ui/app.slint`.
//! They only show what they're sent, the app's Objective-C code stays in charge of Spotify and playback.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::num::NonZeroU32;
use std::rc::{Rc, Weak};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Mutex;

use serde_json::Value;
use slint::platform::femtovg_renderer::{FemtoVGRenderer, OpenGLInterface};
use slint::platform::{
    update_timers_and_animations, EventLoopProxy, Platform, PointerEventButton, Renderer, WindowAdapter, WindowEvent,
};
use slint::{
    Color, ComponentHandle, Image, LogicalPosition, Model, ModelRc, PhysicalSize, PlatformError, Rgba8Pixel,
    SharedPixelBuffer, SharedString, VecModel, Window,
};

slint::include_modules!();

type BoxedError = Box<dyn std::error::Error + Send + Sync>;
type Job = Box<dyn FnOnce() + Send>;
type ActionFn = extern "C" fn(*const c_char, i32, *const c_char);

static SCREEN_FBO: AtomicU32 = AtomicU32::new(0);
static JOBS: Mutex<Vec<Job>> = Mutex::new(Vec::new());
static LOG: Mutex<Option<extern "C" fn(*const c_char)>> = Mutex::new(None);

const RTLD_DEFAULT: *mut c_void = -2isize as *mut c_void;

extern "C" {
    fn dlsym(handle: *mut c_void, name: *const c_char) -> *const c_void;
    fn glBindFramebuffer(target: u32, framebuffer: u32);
}

fn log(message: &str) {
    let log_fn = *LOG.lock().unwrap();
    if let (Some(log_fn), Ok(message)) = (log_fn, CString::new(message)) {
        log_fn(message.as_ptr());
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

/// What the screens show, kept here to change it row by row.
struct Session {
    adapter: Rc<Adapter>,
    ui: App,
    images: RefCell<HashMap<String, Image>>,
    shelves: RefCell<Vec<Rc<VecModel<Tile>>>>,
    library: Rc<VecModel<Tile>>,
    picker: Rc<VecModel<Tile>>,
    tracks: Rc<VecModel<TrackRow>>,
    search: Rc<VecModel<TrackRow>>,
    toast_timer: slint::Timer,
}

thread_local! {
    static SESSION: RefCell<Option<Session>> = const { RefCell::new(None) };
}

fn text(value: &Value, key: &str) -> SharedString {
    value[key].as_str().unwrap_or("").into()
}

fn number(value: &Value, key: &str) -> i32 {
    value[key].as_i64().unwrap_or(0) as i32
}

fn boolean(value: &Value, key: &str) -> bool {
    value[key].as_bool().unwrap_or(false)
}

fn items<'a>(value: &'a Value, key: &str) -> &'a [Value] {
    value[key].as_array().map(Vec::as_slice).unwrap_or(&[])
}

/// "#rrggbb", transparent otherwise, which the screens replace with their own color.
fn color(value: &Value, key: &str) -> Color {
    let parsed = value[key].as_str().and_then(|hex| u32::from_str_radix(hex.strip_prefix('#')?, 16).ok());
    match parsed {
        Some(rgb) => Color::from_argb_encoded(0xFF00_0000 | rgb),
        None => Color::from_argb_u8(0, 0, 0, 0),
    }
}

impl Session {
    fn tile(&self, value: &Value) -> Tile {
        let cover_key = text(value, "cover");
        let image = self.images.borrow().get(cover_key.as_str()).cloned();
        Tile {
            key: text(value, "key"),
            name: text(value, "name"),
            subtitle: text(value, "subtitle"),
            cover_key,
            has_cover: image.is_some(),
            cover: image.unwrap_or_default(),
        }
    }

    fn tiles(&self, values: &[Value]) -> Vec<Tile> {
        values.iter().map(|value| self.tile(value)).collect()
    }

    fn set_image(&self, key: &str, image: Image) {
        let bridge = self.ui.global::<Bridge>();
        if key == "now" {
            bridge.set_now_cover(image);
            bridge.set_now_has_cover(true);
            return;
        }
        self.images.borrow_mut().insert(key.to_string(), image.clone());
        let show = |model: &VecModel<Tile>| {
            for row in 0..model.row_count() {
                let Some(mut tile) = model.row_data(row) else { continue };
                if tile.cover_key == key {
                    tile.cover = image.clone();
                    tile.has_cover = true;
                    model.set_row_data(row, tile);
                }
            }
        };
        show(&self.library);
        show(&self.picker);
        for shelf in self.shelves.borrow().iter() {
            show(shelf);
        }
    }

    fn send(&self, kind: &str, value: &Value) {
        let bridge = self.ui.global::<Bridge>();
        match kind {
            // screen is "loading", "login" or "main".
            "session" => {
                bridge.set_screen(text(value, "screen"));
                bridge.set_login_address(text(value, "address"));
                bridge.set_login_status(text(value, "status"));
            }
            "home" => {
                bridge.set_greeting(text(value, "greeting"));
                let mut models = Vec::new();
                let shelves: Vec<Shelf> = items(value, "shelves")
                    .iter()
                    .map(|shelf| {
                        let model = Rc::new(VecModel::from(self.tiles(items(shelf, "items"))));
                        models.push(model.clone());
                        Shelf { title: text(shelf, "title"), items: ModelRc::from(model) }
                    })
                    .collect();
                *self.shelves.borrow_mut() = models;
                bridge.set_shelves(ModelRc::new(VecModel::from(shelves)));
            }
            "library" => self.library.set_vec(self.tiles(items(value, "items"))),
            "picker" => {
                self.picker.set_vec(self.tiles(items(value, "items")));
                bridge.set_picker_open(boolean(value, "open"));
            }
            // A page of a playlist: reset starts a new list.
            "tracks" => {
                if boolean(value, "reset") {
                    self.tracks.set_vec(Vec::new());
                    bridge.set_tracks_title(text(value, "title"));
                    bridge.set_tracks_open(true);
                }
                for row in items(value, "items") {
                    self.tracks.push(track_row(row));
                }
                bridge.set_tracks_loading(boolean(value, "loading"));
            }
            "search" => {
                self.search.set_vec(items(value, "items").iter().map(track_row).collect::<Vec<_>>());
                bridge.set_search_status(text(value, "status"));
            }
            "search-field" => {
                bridge.set_search_text(text(value, "text"));
                bridge.set_search_editing(boolean(value, "editing"));
            }
            // Liked Songs state of rows from `from` on.
            "saved" => {
                let model = if value["list"].as_str() == Some("search") { &self.search } else { &self.tracks };
                let from = number(value, "from") as usize;
                for (offset, saved) in items(value, "saved").iter().enumerate() {
                    let Some(mut row) = model.row_data(from + offset) else { break };
                    let saved = saved.as_i64().unwrap_or(-1) as i32;
                    if row.saved != saved {
                        row.saved = saved;
                        model.set_row_data(from + offset, row);
                    }
                }
            }
            "now" => {
                bridge.set_now_id(text(value, "id"));
                bridge.set_now_title(text(value, "title"));
                bridge.set_now_subtitle(text(value, "subtitle"));
                bridge.set_now_context(text(value, "context"));
                bridge.set_now_commentary(text(value, "commentary"));
                bridge.set_now_playing(boolean(value, "playing"));
                bridge.set_now_loading(boolean(value, "loading"));
                bridge.set_now_shuffle(boolean(value, "shuffle"));
                bridge.set_now_repeat(number(value, "repeat"));
                bridge.set_now_saved(number(value, "saved"));
                bridge.set_now_has_lyrics(boolean(value, "has_lyrics"));
                bridge.set_now_has_video(boolean(value, "has_video"));
                bridge.set_now_tint(color(value, "tint"));
                if !boolean(value, "has_cover") {
                    bridge.set_now_has_cover(false);
                }
            }
            "volume" => bridge.set_volume(value["volume"].as_f64().unwrap_or(0.0) as f32),
            "open-now" => bridge.set_now_open(true),
            "lyrics" => {
                let lines: Vec<SharedString> =
                    items(value, "lines").iter().map(|line| line.as_str().unwrap_or("").into()).collect();
                bridge.set_lyrics(ModelRc::new(VecModel::from(lines)));
                bridge.set_lyrics_synced(boolean(value, "synced"));
                bridge.set_lyrics_background(color(value, "background"));
                bridge.set_lyrics_text(color(value, "text"));
                bridge.set_lyrics_highlight(color(value, "highlight"));
            }
            "sheet" => {
                bridge.set_sheet_title(text(value, "title"));
                bridge.set_sheet_open(true);
            }
            "toast" => {
                bridge.set_toast(text(value, "text"));
                bridge.set_toast_visible(true);
                let ui = self.ui.as_weak();
                self.toast_timer.start(slint::TimerMode::SingleShot, std::time::Duration::from_secs(2), move || {
                    if let Some(ui) = ui.upgrade() {
                        ui.global::<Bridge>().set_toast_visible(false);
                    }
                });
            }
            _ => log(&format!("Unknown UI update {kind}")),
        }
    }
}

fn track_row(value: &Value) -> TrackRow {
    TrackRow {
        id: text(value, "id"),
        title: text(value, "title"),
        subtitle: text(value, "subtitle"),
        saved: value["saved"].as_i64().unwrap_or(-1) as i32,
    }
}

fn start(width: u32, height: u32, scale: f32, present: extern "C" fn(), action: ActionFn) -> Result<(), BoxedError> {
    let adapter = Rc::new(RefCell::new(None));
    slint::platform::set_platform(Box::new(AppPlatform { present, adapter: adapter.clone() }))?;

    let ui = App::new()?;
    let adapter = adapter.borrow().clone().ok_or("Slint made no window")?;

    let session = Session {
        adapter: adapter.clone(),
        ui: ui.clone_strong(),
        images: RefCell::default(),
        shelves: RefCell::default(),
        library: Rc::default(),
        picker: Rc::default(),
        tracks: Rc::default(),
        search: Rc::default(),
        toast_timer: slint::Timer::default(),
    };

    let bridge = ui.global::<Bridge>();
    bridge.set_library(ModelRc::from(session.library.clone()));
    bridge.set_picker(ModelRc::from(session.picker.clone()));
    bridge.set_tracks(ModelRc::from(session.tracks.clone()));
    bridge.set_search(ModelRc::from(session.search.clone()));
    bridge.on_action(move |name, index, text| {
        if let (Ok(name), Ok(text)) = (CString::new(name.as_str()), CString::new(text.as_str())) {
            action(name.as_ptr(), index, text.as_ptr());
        }
    });

    let size = PhysicalSize::new(width, height);
    adapter.size.set(size);
    adapter.window.dispatch_event(WindowEvent::ScaleFactorChanged { scale_factor: scale });
    adapter.window.dispatch_event(WindowEvent::Resized { size: size.to_logical(scale) });
    ui.show()?;

    SESSION.with(|slot| *slot.borrow_mut() = Some(session));
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
    action: ActionFn,
) -> i32 {
    *LOG.lock().unwrap() = Some(log_fn);
    SCREEN_FBO.store(fbo, Ordering::Relaxed);
    match start(width, height, scale, present, action) {
        Ok(()) => 0,
        Err(error) => {
            log(&format!("Couldn't start the UI: {error}"));
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
        if let Err(error) = adapter.renderer.render() {
            log(&format!("Couldn't render: {error}"));
        }
    });
}

#[no_mangle]
pub extern "C" fn fm_ui_touch(phase: i32, x: f32, y: f32) {
    // A screen's callback can come back here through the app, so nothing stays borrowed while dispatching.
    let Some(window) = SESSION.with(|session| Some(session.borrow().as_ref()?.ui.as_weak())) else { return };
    let Some(ui) = window.upgrade() else { return };
    let window = ui.window();
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
}

/// # Safety
/// Both are C strings.
#[no_mangle]
pub unsafe extern "C" fn fm_ui_send(kind: *const c_char, json: *const c_char) {
    let kind = CStr::from_ptr(kind).to_string_lossy();
    let value: Value = match serde_json::from_slice(CStr::from_ptr(json).to_bytes()) {
        Ok(value) => value,
        Err(error) => {
            log(&format!("Unreadable UI update {kind}: {error}"));
            return;
        }
    };
    SESSION.with(|session| {
        if let Some(session) = session.borrow().as_ref() {
            session.send(&kind, &value);
        }
    });
}

#[no_mangle]
pub extern "C" fn fm_ui_progress(position: f32, duration: f32, lyric_line: i32) {
    SESSION.with(|session| {
        let session = session.borrow();
        let Some(session) = session.as_ref() else { return };
        let bridge = session.ui.global::<Bridge>();
        bridge.set_position(position);
        bridge.set_duration(duration);
        bridge.set_lyrics_line(lyric_line);
    });
}

/// # Safety
/// `key` is a C string, `rgba` has width * height * 4 bytes.
#[no_mangle]
pub unsafe extern "C" fn fm_ui_image(key: *const c_char, rgba: *const u8, width: u32, height: u32) {
    let key = CStr::from_ptr(key).to_string_lossy();
    let pixels = std::slice::from_raw_parts(rgba, width as usize * height as usize * 4);
    let buffer = SharedPixelBuffer::<Rgba8Pixel>::clone_from_slice(pixels, width, height);
    let image = Image::from_rgba8_premultiplied(buffer);
    SESSION.with(|session| {
        if let Some(session) = session.borrow().as_ref() {
            session.set_image(&key, image);
        }
    });
}
