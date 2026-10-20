//! C interface to librespot: Spotify Connect login, saved credentials, Web API tokens and playback.
//! There is one session per process. Decoded audio plays through an Audio Queue and is never
//! written to disk; the cache folder only holds the reusable login and the device ID.

use std::ffi::{c_char, c_void, CStr, CString};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use futures_util::StreamExt;
use librespot::core::authentication::Credentials;
use librespot::core::cache::Cache;
use librespot::core::config::{DeviceType, SessionConfig};
use librespot::core::session::Session;
use librespot::core::spotify_uri::SpotifyUri;
use librespot::discovery::Discovery;
use librespot::playback::audio_backend::{Sink, SinkResult};
use librespot::playback::config::PlayerConfig;
use librespot::playback::convert::Converter;
use librespot::playback::decoder::AudioPacket;
use librespot::playback::mixer::NoOpVolume;
use librespot::playback::player::{Player, PlayerEvent};
use tokio::runtime::Runtime;
use tokio::task::JoinHandle;

use crate::audio::AudioQueueSink;

/// Receives events, see `FM_LIBRESPOT_EVENT_*` in fmlibrespot.h. `detail` (a track URI, user name or
/// error message) is only valid during the call. Called on a background thread.
pub type FmEventCallback =
    extern "C" fn(context: *mut c_void, event: i32, position_ms: u32, detail: *const c_char);

pub const EVENT_PLAYING: i32 = 1;
pub const EVENT_PAUSED: i32 = 2;
pub const EVENT_STOPPED: i32 = 3;
pub const EVENT_END_OF_TRACK: i32 = 4;
pub const EVENT_UNAVAILABLE: i32 = 5;
pub const EVENT_LOADING: i32 = 6;
pub const EVENT_LOGGED_IN: i32 = 7;
pub const EVENT_LOGIN_FAILED: i32 = 8;
pub const EVENT_DISCOVERY_STOPPED: i32 = 9;
pub const EVENT_LOG: i32 = 10;

/// The context pointer belongs to FoxMusic, which promises it's usable from any thread.
#[derive(Clone, Copy)]
struct Context(*mut c_void);
unsafe impl Send for Context {}
unsafe impl Sync for Context {}

impl Context {
    // A method (instead of `.0`) makes closures capture the whole Send wrapper, not the raw pointer.
    fn get(self) -> *mut c_void {
        self.0
    }
}

#[derive(Clone, Copy)]
struct Events {
    context: Context,
    callback: FmEventCallback,
}

impl Events {
    fn send(&self, event: i32, position_ms: u32, detail: &str) {
        let detail = CString::new(detail.replace('\0', "")).unwrap_or_default();
        (self.callback)(self.context.get(), event, position_ms, detail.as_ptr());
    }
}

struct Active {
    session: Session,
    player: Arc<Player>,
}

struct State {
    runtime: Runtime,
    cache_dir: PathBuf,
    device_id: String,
    events: Events,
    active: Mutex<Option<Active>>,
    discovery: Mutex<Option<JoinHandle<()>>>,
}

static STATE: OnceLock<State> = OnceLock::new();

/// Forwards librespot's log messages to FoxMusic (FM_LIBRESPOT_EVENT_LOG), which NSLogs them.
struct EventLogger {
    events: Events,
}

impl log::Log for EventLogger {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        // Debug for librespot itself, only warnings from the networking and TLS crates underneath.
        let limit = if metadata.target().starts_with("librespot") || metadata.target().starts_with("fmlibrespot") {
            log::Level::Debug
        } else {
            log::Level::Warn
        };
        metadata.level() <= limit
    }

    fn log(&self, record: &log::Record) {
        if self.enabled(record.metadata()) {
            let message = format!("[{}] {}: {}", record.level(), record.target(), record.args());
            self.events.send(EVENT_LOG, 0, &message);
        }
    }

    fn flush(&self) {}
}

/// Used when the audio queue couldn't be created, so the player still runs and reports events.
struct SilentSink;

impl Sink for SilentSink {
    fn write(&mut self, _packet: AudioPacket, _converter: &mut Converter) -> SinkResult<()> {
        Ok(())
    }
}

fn make_sink() -> Box<dyn Sink> {
    match AudioQueueSink::new() {
        Ok(sink) => Box::new(sink),
        Err(status) => {
            log::error!("Couldn't create audio queue: {status}");
            Box::new(SilentSink)
        }
    }
}

fn set_error(error_out: *mut *mut c_char, message: impl Into<String>) {
    if !error_out.is_null() {
        let message = CString::new(message.into().replace('\0', "")).unwrap_or_default();
        unsafe { *error_out = message.into_raw() };
    }
}

unsafe fn str_arg<'a>(value: *const c_char) -> Option<&'a str> {
    if value.is_null() {
        None
    } else {
        CStr::from_ptr(value).to_str().ok()
    }
}

/// The device ID has to stay the same: Connect credentials are encrypted for it.
fn load_device_id(cache_dir: &Path) -> String {
    let path = cache_dir.join("device_id");
    if let Ok(id) = fs::read_to_string(&path) {
        let id = id.trim();
        if !id.is_empty() {
            return id.to_string();
        }
    }
    let id = SessionConfig::default().device_id;
    let _ = fs::write(&path, &id);
    id
}

impl State {
    fn session_config(&self) -> SessionConfig {
        SessionConfig { device_id: self.device_id.clone(), ..SessionConfig::default() }
    }

    fn cache(&self) -> Result<Cache, String> {
        // Credentials only: no volume file and, deliberately, no audio cache.
        Cache::new(Some(&self.cache_dir), None, None, None).map_err(|e| e.to_string())
    }

    fn saved_credentials(&self) -> Option<Credentials> {
        self.cache().ok()?.credentials()
    }

    /// Logs in and replaces the current session. Saves reusable credentials for the next launch.
    async fn connect(&self, credentials: Credentials) -> Result<String, String> {
        let config = self.session_config();
        // Shows which identity this build logs in with, see patches/librespot-core.
        log::info!(
            "Logging in as os={} client_id={} device_id={} auth_type={:?}",
            librespot::core::config::OS,
            config.client_id,
            config.device_id,
            credentials.auth_type
        );
        let session = Session::new(config, Some(self.cache()?));
        session.connect(credentials, true).await.map_err(|e| e.to_string())?;

        let player = Player::new(PlayerConfig::default(), session.clone(), Box::new(NoOpVolume), make_sink);
        let events = self.events;
        let mut player_events = player.get_player_event_channel();
        tokio::spawn(async move {
            while let Some(event) = player_events.recv().await {
                let (kind, position_ms, uri) = match event {
                    PlayerEvent::Playing { position_ms, track_id, .. } => (EVENT_PLAYING, position_ms, track_id),
                    PlayerEvent::Paused { position_ms, track_id, .. } => (EVENT_PAUSED, position_ms, track_id),
                    PlayerEvent::Stopped { track_id, .. } => (EVENT_STOPPED, 0, track_id),
                    PlayerEvent::EndOfTrack { track_id, .. } => (EVENT_END_OF_TRACK, 0, track_id),
                    PlayerEvent::Unavailable { track_id, .. } => (EVENT_UNAVAILABLE, 0, track_id),
                    PlayerEvent::Loading { position_ms, track_id, .. } => (EVENT_LOADING, position_ms, track_id),
                    _ => continue,
                };
                events.send(kind, position_ms, &uri.to_uri().unwrap_or_default());
            }
        });

        let username = session.username();
        let previous = self.active.lock().unwrap_or_else(|e| e.into_inner()).replace(Active { session, player });
        if let Some(previous) = previous {
            previous.player.stop();
            previous.session.shutdown();
        }
        Ok(username)
    }

    /// The current session, logging back in with the saved credentials if there is none or it dropped.
    fn session(&self) -> Result<(Session, Arc<Player>), String> {
        if let Some(active) = self.active.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
            if !active.session.is_invalid() {
                return Ok((active.session.clone(), active.player.clone()));
            }
        }
        let credentials = self.saved_credentials().ok_or("Not logged in to Spotify")?;
        self.runtime.block_on(self.connect(credentials))?;
        let active = self.active.lock().unwrap_or_else(|e| e.into_inner());
        let active = active.as_ref().ok_or("Not logged in to Spotify")?;
        Ok((active.session.clone(), active.player.clone()))
    }
}

fn state() -> Option<&'static State> {
    STATE.get()
}

/// How long an idle runtime takes to start a task spawned from another thread, or None if it didn't
/// within two seconds. With one worker, the worker sleeps in kqueue and only mio's EVFILT_USER event
/// can wake it. When that doesn't work, librespot's packets (audio key requests among them) wait
/// until unrelated network traffic or a timer wakes the runtime.
fn idle_wake_latency() -> Option<Duration> {
    let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(1).enable_all().build().ok()?;
    // Gives the worker time to go to sleep.
    std::thread::sleep(Duration::from_millis(100));
    let (tx, rx) = std::sync::mpsc::channel();
    let start = Instant::now();
    runtime.spawn(async move {
        let _ = tx.send(start.elapsed());
    });
    let latency = rx.recv_timeout(Duration::from_secs(2)).ok();
    runtime.shutdown_background();
    latency
}

/// Wakes the runtime every 10 ms so work handed over from other threads gets picked up even if the
/// waker doesn't work, see idle_wake_latency.
fn start_wake_ticker(runtime: &Runtime) {
    runtime.spawn(async {
        let mut interval = tokio::time::interval(Duration::from_millis(10));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            interval.tick().await;
        }
    });
}

/// Sets up librespot. `cache_dir` is where the login and device ID are kept. Call once, before anything else.
#[no_mangle]
pub unsafe extern "C" fn fm_librespot_init(
    cache_dir: *const c_char,
    context: *mut c_void,
    event_callback: FmEventCallback,
    error_out: *mut *mut c_char,
) -> bool {
    if STATE.get().is_some() {
        return true;
    }
    let Some(cache_dir) = str_arg(cache_dir) else {
        set_error(error_out, "Missing cache folder");
        return false;
    };
    let cache_dir = PathBuf::from(cache_dir);
    if let Err(error) = fs::create_dir_all(&cache_dir) {
        set_error(error_out, format!("Couldn't create {}: {error}", cache_dir.display()));
        return false;
    }
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("fm-librespot")
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            set_error(error_out, format!("Couldn't start runtime: {error}"));
            return false;
        }
    };
    let device_id = load_device_id(&cache_dir);
    let events = Events { context: Context(context), callback: event_callback };
    if log::set_boxed_logger(Box::new(EventLogger { events })).is_ok() {
        log::set_max_level(log::LevelFilter::Debug);
    }
    match idle_wake_latency() {
        Some(latency) if latency < Duration::from_millis(200) => {
            log::info!("Runtime wakes up in {latency:?} when given work from another thread");
        }
        latency => {
            log::warn!("Runtime wake-up is broken ({latency:?}), waking it every 10 ms instead");
            start_wake_ticker(&runtime);
        }
    }
    let _ = STATE.set(State {
        runtime,
        cache_dir,
        device_id,
        events,
        active: Mutex::new(None),
        discovery: Mutex::new(None),
    });
    true
}

/// Whether there is a session or a saved login to restore one from.
#[no_mangle]
pub extern "C" fn fm_librespot_has_login() -> bool {
    let Some(state) = state() else { return false };
    state.active.lock().unwrap_or_else(|e| e.into_inner()).is_some() || state.saved_credentials().is_some()
}

/// Logs in with the saved credentials unless already logged in. Blocks while connecting.
#[no_mangle]
pub unsafe extern "C" fn fm_librespot_restore_session(error_out: *mut *mut c_char) -> bool {
    let Some(state) = state() else {
        set_error(error_out, "librespot isn't initialised");
        return false;
    };
    match state.session() {
        Ok(_) => true,
        Err(error) => {
            set_error(error_out, error);
            false
        }
    }
}

/// Announces FoxMusic as a Spotify Connect device on the local network. Picking it in the Spotify app on
/// another device logs in: FM_LIBRESPOT_EVENT_LOGGED_IN (detail: user name) or _LOGIN_FAILED (message).
#[no_mangle]
pub unsafe extern "C" fn fm_librespot_start_discovery(device_name: *const c_char, error_out: *mut *mut c_char) -> bool {
    let Some(state) = state() else {
        set_error(error_out, "librespot isn't initialised");
        return false;
    };
    let name = str_arg(device_name).unwrap_or("FoxMusic").to_string();
    let mut discovery_task = state.discovery.lock().unwrap_or_else(|e| e.into_inner());
    if discovery_task.as_ref().is_some_and(|task| !task.is_finished()) {
        return true;
    }

    let client_id = SessionConfig::default().client_id;
    let discovery = state.runtime.block_on(async {
        Discovery::builder(state.device_id.clone(), client_id)
            .name(name)
            .device_type(DeviceType::Smartphone)
            .launch()
    });
    let mut discovery = match discovery {
        Ok(discovery) => discovery,
        Err(error) => {
            set_error(error_out, format!("Couldn't announce FoxMusic on the network: {error}"));
            return false;
        }
    };

    *discovery_task = Some(state.runtime.spawn(async move {
        while let Some(credentials) = discovery.next().await {
            match state.connect(credentials).await {
                Ok(username) => state.events.send(EVENT_LOGGED_IN, 0, &username),
                Err(error) => state.events.send(EVENT_LOGIN_FAILED, 0, &error),
            }
        }
        state.events.send(EVENT_DISCOVERY_STOPPED, 0, "Spotify Connect discovery stopped");
    }));
    true
}

#[no_mangle]
pub extern "C" fn fm_librespot_stop_discovery() {
    if let Some(state) = state() {
        if let Some(task) = state.discovery.lock().unwrap_or_else(|e| e.into_inner()).take() {
            // Dropping Discovery inside the task unregisters the Bonjour service.
            task.abort();
        }
    }
}

/// Gets a Web API access token for comma separated `scopes` from the session (logging in with the saved
/// credentials if needed). Blocks. Free the token with fm_librespot_free_string.
#[no_mangle]
pub unsafe extern "C" fn fm_librespot_web_api_token(
    scopes: *const c_char,
    token_out: *mut *mut c_char,
    expires_in_out: *mut u32,
    error_out: *mut *mut c_char,
) -> bool {
    let Some(state) = state() else {
        set_error(error_out, "librespot isn't initialised");
        return false;
    };
    let scopes = str_arg(scopes).unwrap_or("streaming");
    let session = match state.session() {
        Ok((session, _)) => session,
        Err(error) => {
            set_error(error_out, error);
            return false;
        }
    };
    // login5 is what librespot itself uses for Spotify's HTTP APIs. The keymaster token endpoint behind
    // token_provider() goes over Mercury and Spotify no longer answers it ("Error handling mercury
    // response"), so it's only a fallback. login5 tokens have no scope list, `scopes` only matters there.
    let token = state.runtime.block_on(async {
        match session.login5().auth_token().await {
            Ok(token) => Ok(token),
            Err(login5_error) => {
                log::warn!("login5 token failed ({login5_error}), trying keymaster");
                session.token_provider().get_token(scopes).await
            }
        }
    });
    match token {
        Ok(token) => {
            if !token_out.is_null() {
                *token_out = CString::new(token.access_token).unwrap_or_default().into_raw();
            }
            if !expires_in_out.is_null() {
                *expires_in_out = token.expires_in.as_secs().min(u64::from(u32::MAX)) as u32;
            }
            true
        }
        Err(error) => {
            set_error(error_out, format!("Couldn't get a Web API token: {error}"));
            false
        }
    }
}

/// Logs out and forgets the saved login.
#[no_mangle]
pub extern "C" fn fm_librespot_logout() {
    let Some(state) = state() else { return };
    if let Some(active) = state.active.lock().unwrap_or_else(|e| e.into_inner()).take() {
        active.player.stop();
        active.session.shutdown();
    }
    let _ = fs::remove_file(state.cache_dir.join("credentials.json"));
}

/// Loads a track by URI, e.g. "spotify:track:4cOdK2wGLETKBW3PvgPWqT". Blocks if it has to log in first.
#[no_mangle]
pub unsafe extern "C" fn fm_librespot_load(
    uri: *const c_char,
    start_playing: bool,
    position_ms: u32,
    error_out: *mut *mut c_char,
) -> bool {
    let Some(state) = state() else {
        set_error(error_out, "librespot isn't initialised");
        return false;
    };
    let Some(uri) = str_arg(uri) else {
        set_error(error_out, "Missing track URI");
        return false;
    };
    let uri = match SpotifyUri::from_uri(uri) {
        Ok(uri) => uri,
        Err(_) => {
            set_error(error_out, format!("Invalid track URI: {uri}"));
            return false;
        }
    };
    match state.session() {
        Ok((_, player)) => {
            let _guard = state.runtime.enter();
            player.load(uri, start_playing, position_ms);
            true
        }
        Err(error) => {
            set_error(error_out, error);
            false
        }
    }
}

fn with_player(action: impl FnOnce(&Player)) {
    if let Some(state) = state() {
        if let Some(active) = state.active.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
            let _guard = state.runtime.enter();
            action(&active.player);
        }
    }
}

#[no_mangle]
pub extern "C" fn fm_librespot_play() {
    with_player(|player| player.play());
}

#[no_mangle]
pub extern "C" fn fm_librespot_pause() {
    with_player(|player| player.pause());
}

#[no_mangle]
pub extern "C" fn fm_librespot_stop() {
    with_player(|player| player.stop());
}

#[no_mangle]
pub extern "C" fn fm_librespot_seek(position_ms: u32) {
    with_player(|player| player.seek(position_ms));
}
