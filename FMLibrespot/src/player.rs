//! C interface to librespot: Spotify Connect login, saved credentials, Web API tokens and playback.
//! There is one session per process, and it runs a Spotify Connect device (Spirc): Retrofy shows up in
//! the other Spotify apps' device lists, and its own playback goes through the same device, so the queue,
//! shuffle and repeat follow Spotify's context logic. Decoded audio plays through an Audio Queue and is never
//! written to disk; the cache folder only holds the reusable login and the device ID.

use std::ffi::{c_char, c_void, CStr, CString};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use futures_util::StreamExt;
use librespot::connect::{ConnectConfig, LoadContextOptions, LoadRequest, LoadRequestOptions, Options, PlayingTrack, Spirc};
use librespot::core::authentication::Credentials;
use librespot::core::cache::Cache;
use librespot::core::config::{DeviceType, SessionConfig};
use librespot::core::session::Session;
use librespot::core::spotify_id::SpotifyId;
use librespot::core::spotify_uri::SpotifyUri;
use librespot::discovery::Discovery;
use librespot::metadata::audio::{AudioItem, UniqueFields};
use librespot::metadata::image::{Image, ImageSize};
use librespot::metadata::{Metadata, Playlist, Track};
use librespot::playback::audio_backend::{Sink, SinkResult};
use librespot::playback::config::PlayerConfig;
use librespot::playback::convert::Converter;
use librespot::playback::decoder::AudioPacket;
use librespot::playback::mixer::softmixer::SoftMixer;
use librespot::playback::mixer::{Mixer, MixerConfig};
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
/// The Connect device's track changed, detail is the track as Web API JSON.
pub const EVENT_TRACK_CHANGED: i32 = 11;
/// A new playback position while playing or after seeking.
pub const EVENT_POSITION: i32 = 12;
/// position_ms is 1 when shuffling.
pub const EVENT_SHUFFLE: i32 = 13;
/// position_ms is 0 (off), 1 (repeat the context) or 2 (repeat the track).
pub const EVENT_REPEAT: i32 = 14;
/// position_ms is the volume, 0 to 65535.
pub const EVENT_VOLUME: i32 = 15;
/// Another device took over playback.
pub const EVENT_INACTIVE: i32 = 16;

/// The context pointer belongs to Retrofy, which promises it's usable from any thread.
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
    spirc: Spirc,
}

const SESSION_CHECK_INTERVAL: Duration = Duration::from_secs(5);

struct State {
    runtime: Runtime,
    cache_dir: PathBuf,
    device_id: String,
    events: Events,
    active: Mutex<Option<Active>>,
    discovery: Mutex<Option<JoinHandle<()>>>,
    /// Held while logging back in, so the watchdog and a Play press don't both replace the session.
    reconnecting: Mutex<()>,
}

static STATE: OnceLock<State> = OnceLock::new();

/// Forwards librespot's log messages to Retrofy (FM_LIBRESPOT_EVENT_LOG), which NSLogs them.
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
        // One Connect device per process: the previous one has to go before the new session registers.
        let previous = self.active.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some(previous) = previous {
            let _ = previous.spirc.shutdown();
            previous.player.stop();
            previous.session.shutdown();
        }

        let session = Session::new(config, Some(self.cache()?));
        // Soft volume so other devices can change Retrofy's volume. It starts at full, the phone's own
        // volume buttons work on top of it.
        let mixer: Arc<dyn Mixer> = Arc::new(SoftMixer::open(MixerConfig::default()).map_err(|e| e.to_string())?);
        let player_config = PlayerConfig { position_update_interval: Some(Duration::from_secs(1)), ..PlayerConfig::default() };
        let player = Player::new(player_config, session.clone(), mixer.get_soft_volume(), make_sink);
        forward_player_events(self.events, &player);

        let connect_config = ConnectConfig {
            name: "Retrofy".to_string(),
            device_type: DeviceType::Smartphone,
            initial_volume: u16::MAX,
            ..ConnectConfig::default()
        };
        // Spirc logs the session in (saving the credentials) once its message listeners are registered.
        let (spirc, task) = Spirc::new(connect_config, session.clone(), credentials, player.clone(), mixer)
            .await
            .map_err(|e| e.to_string())?;
        tokio::spawn(task);

        let username = session.username();
        *self.active.lock().unwrap_or_else(|e| e.into_inner()) = Some(Active { session, player, spirc });
        Ok(username)
    }

    /// The current session, logging back in with the saved credentials if there is none or it dropped.
    fn session(&self) -> Result<(Session, Arc<Player>), String> {
        if let Some(active) = self.active.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
            if !active.session.is_invalid() {
                return Ok((active.session.clone(), active.player.clone()));
            }
        }
        let _reconnecting = self.reconnecting.lock().unwrap_or_else(|e| e.into_inner());
        // Whoever held the lock may have just done this.
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

    /// Spotify closes connections now and then, which ends the Connect device and takes Retrofy out of the
    /// other devices' lists. Nothing else notices until Play is pressed.
    fn watch_session(&'static self) {
        let watchdog = std::thread::Builder::new().name("fm-session-watchdog".into()).spawn(move || loop {
            std::thread::sleep(SESSION_CHECK_INTERVAL);
            let is_invalid = self
                .active
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .as_ref()
                .is_some_and(|active| active.session.is_invalid());
            if is_invalid {
                log::info!("Session ended, reconnecting");
                self.events.send(EVENT_INACTIVE, 0, "");
                if let Err(error) = self.session() {
                    log::warn!("Couldn't reconnect: {error}");
                }
            }
        });
        if let Err(error) = watchdog {
            log::warn!("Couldn't start the session watchdog: {error}");
        }
    }
}

/// Sends the player's events to Retrofy, see the EVENT_ constants.
fn forward_player_events(events: Events, player: &Player) {
    let mut player_events = player.get_player_event_channel();
    tokio::spawn(async move {
        while let Some(event) = player_events.recv().await {
            let uri = |track_id: SpotifyUri| track_id.to_uri().unwrap_or_default();
            match event {
                PlayerEvent::Playing { position_ms, track_id, .. } => events.send(EVENT_PLAYING, position_ms, &uri(track_id)),
                PlayerEvent::Paused { position_ms, track_id, .. } => events.send(EVENT_PAUSED, position_ms, &uri(track_id)),
                PlayerEvent::Stopped { track_id, .. } => events.send(EVENT_STOPPED, 0, &uri(track_id)),
                PlayerEvent::EndOfTrack { track_id, .. } => events.send(EVENT_END_OF_TRACK, 0, &uri(track_id)),
                PlayerEvent::Unavailable { track_id, .. } => events.send(EVENT_UNAVAILABLE, 0, &uri(track_id)),
                PlayerEvent::Loading { position_ms, track_id, .. } => events.send(EVENT_LOADING, position_ms, &uri(track_id)),
                PlayerEvent::PositionChanged { position_ms, track_id, .. }
                | PlayerEvent::Seeked { position_ms, track_id, .. }
                | PlayerEvent::PositionCorrection { position_ms, track_id, .. } => {
                    events.send(EVENT_POSITION, position_ms, &uri(track_id))
                }
                PlayerEvent::TrackChanged { audio_item } => events.send(EVENT_TRACK_CHANGED, 0, &audio_item_json(&audio_item)),
                PlayerEvent::ShuffleChanged { shuffle } => events.send(EVENT_SHUFFLE, shuffle as u32, ""),
                PlayerEvent::RepeatChanged { context, track } => {
                    events.send(EVENT_REPEAT, if track { 2 } else if context { 1 } else { 0 }, "")
                }
                PlayerEvent::VolumeChanged { volume } => events.send(EVENT_VOLUME, u32::from(volume), ""),
                PlayerEvent::SessionDisconnected { .. } => events.send(EVENT_INACTIVE, 0, ""),
                _ => {}
            }
        }
    });
}

/// A track in the Web API's JSON shape, which FMSpotifyTrack reads.
fn audio_item_json(item: &AudioItem) -> String {
    let (artists, album): (Vec<String>, String) = match &item.unique_fields {
        UniqueFields::Track { artists, album, .. } => (artists.iter().map(|artist| artist.name.clone()).collect(), album.clone()),
        UniqueFields::Episode { show_name, .. } => (vec![show_name.clone()], show_name.clone()),
        UniqueFields::Local { artists, album, .. } => (artists.iter().cloned().collect(), album.clone().unwrap_or_default()),
    };
    let artists = artists.iter().map(|name| format!("{{\"name\":{}}}", json_string(name))).collect::<Vec<_>>().join(",");
    let images = item
        .covers
        .iter()
        .max_by_key(|cover| cover.width)
        .map(|cover| format!("{{\"url\":{}}}", json_string(&cover.url)))
        .unwrap_or_default();
    let id = item.uri.rsplit(':').next().unwrap_or_default();
    format!(
        "{{\"id\":{},\"uri\":{},\"name\":{},\"duration_ms\":{},\"album\":{{\"name\":{},\"images\":[{images}]}},\"artists\":[{artists}]}}",
        json_string(id),
        json_string(&item.uri),
        json_string(&item.name),
        item.duration_ms,
        json_string(&album)
    )
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
        reconnecting: Mutex::new(()),
    });
    if let Some(state) = STATE.get() {
        state.watch_session();
    }
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

/// Announces Retrofy as a Spotify Connect device on the local network. Picking it in the Spotify app on
/// another device logs in: FM_LIBRESPOT_EVENT_LOGGED_IN (detail: user name) or _LOGIN_FAILED (message).
#[no_mangle]
pub unsafe extern "C" fn fm_librespot_start_discovery(device_name: *const c_char, error_out: *mut *mut c_char) -> bool {
    let Some(state) = state() else {
        set_error(error_out, "librespot isn't initialised");
        return false;
    };
    let name = str_arg(device_name).unwrap_or("Retrofy").to_string();
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
            set_error(error_out, format!("Couldn't announce Retrofy on the network: {error}"));
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
        let _ = active.spirc.shutdown();
        active.player.stop();
        active.session.shutdown();
    }
    let _ = fs::remove_file(state.cache_dir.join("credentials.json"));
}

fn with_spirc(action: impl FnOnce(&Spirc) -> Result<(), librespot::core::Error>) {
    if let Some(state) = state() {
        if let Some(active) = state.active.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
            if let Err(error) = action(&active.spirc) {
                log::warn!("Spotify Connect command failed: {error}");
            }
        }
    }
}

/// Starts playing on Retrofy's Connect device, taking over from whichever device was playing. `tracks` is
/// either a context URI (spotify:playlist:..., spotify:album:..., or "spotify:collection" for Liked Songs)
/// with `start_uri` the track to start at, or a JSON array of track URIs with `start_index`. Starts
/// `position_ms` into that track. Blocks if it has to log in first.
#[no_mangle]
pub unsafe extern "C" fn fm_connect_play_context(
    context_uri: *const c_char,
    track_uris_json: *const c_char,
    start_uri: *const c_char,
    start_index: u32,
    shuffle: bool,
    position_ms: u32,
    error_out: *mut *mut c_char,
) -> bool {
    let Some(state) = state() else {
        set_error(error_out, "librespot isn't initialised");
        return false;
    };
    let session = match state.session() {
        Ok((session, _)) => session,
        Err(error) => {
            set_error(error_out, error);
            return false;
        }
    };
    let playing_track = match str_arg(start_uri) {
        Some(uri) if !uri.is_empty() => Some(PlayingTrack::Uri(uri.to_string())),
        // u32::MAX: no start track, Spotify picks one (a random one when shuffling).
        _ if start_index == u32::MAX => None,
        _ => Some(PlayingTrack::Index(start_index)),
    };
    let options = LoadRequestOptions {
        start_playing: true,
        seek_to: position_ms,
        context_options: Some(LoadContextOptions::Options(Options { shuffle, ..Options::default() })),
        playing_track,
    };
    let request = match (str_arg(context_uri), str_arg(track_uris_json)) {
        (Some(context), _) if !context.is_empty() => {
            let context = if context == "spotify:collection" {
                format!("spotify:user:{}:collection", session.username())
            } else {
                context.to_string()
            };
            LoadRequest::from_context_uri(context, options)
        }
        (_, Some(json)) => {
            let uris: Vec<String> = json
                .trim_matches(|c| c == '[' || c == ']')
                .split(',')
                .map(|uri| uri.trim().trim_matches('"').to_string())
                .filter(|uri| !uri.is_empty())
                .collect();
            LoadRequest::from_tracks(uris, options)
        }
        _ => {
            set_error(error_out, "Nothing to play");
            return false;
        }
    };
    let active = state.active.lock().unwrap_or_else(|e| e.into_inner());
    let Some(active) = active.as_ref() else {
        set_error(error_out, "Not logged in to Spotify");
        return false;
    };
    match active.spirc.activate().and_then(|_| active.spirc.load(request)) {
        Ok(()) => true,
        Err(error) => {
            set_error(error_out, format!("Couldn't start playback: {error}"));
            false
        }
    }
}

#[no_mangle]
pub extern "C" fn fm_librespot_play() {
    with_spirc(|spirc| spirc.play());
}

#[no_mangle]
pub extern "C" fn fm_librespot_pause() {
    with_spirc(|spirc| spirc.pause());
}

#[no_mangle]
pub extern "C" fn fm_librespot_seek(position_ms: u32) {
    with_spirc(|spirc| spirc.set_position_ms(position_ms));
}

#[no_mangle]
pub extern "C" fn fm_connect_next() {
    with_spirc(|spirc| spirc.next());
}

#[no_mangle]
pub extern "C" fn fm_connect_previous() {
    with_spirc(|spirc| spirc.prev());
}

#[no_mangle]
pub extern "C" fn fm_connect_set_shuffle(shuffle: bool) {
    with_spirc(|spirc| spirc.shuffle(shuffle));
}

/// 0 off, 1 repeat the context, 2 repeat the track.
#[no_mangle]
pub extern "C" fn fm_connect_set_repeat(mode: u32) {
    with_spirc(|spirc| {
        spirc.repeat(mode == 1)?;
        spirc.repeat_track(mode == 2)
    });
}

fn json_string(value: &str) -> String {
    let mut json = String::with_capacity(value.len() + 2);
    json.push('"');
    for c in value.chars() {
        match c {
            '"' => json.push_str("\\\""),
            '\\' => json.push_str("\\\\"),
            '\n' => json.push_str("\\n"),
            '\r' => json.push_str("\\r"),
            '\t' => json.push_str("\\t"),
            c if (c as u32) < 0x20 => json.push_str(&format!("\\u{:04x}", c as u32)),
            c => json.push(c),
        }
    }
    json.push('"');
    json
}

/// Biggest first, the order the Web API uses (Retrofy takes the first image as the album art).
fn image_rank(image: &Image) -> (i32, i32) {
    let size = match image.size {
        ImageSize::SMALL => 0,
        ImageSize::DEFAULT => 1,
        ImageSize::LARGE => 2,
        _ => 3,
    };
    (image.width, size)
}

/// A track in the Web API's JSON shape: id, name, duration_ms, album (name, images) and artists.
fn track_json(track: &Track) -> Option<String> {
    let SpotifyUri::Track { id } = &track.id else { return None };
    let id = id.to_base62().ok()?;

    let mut covers: Vec<&Image> = track.album.covers.iter().collect();
    if covers.is_empty() {
        covers = track.album.cover_group.iter().collect();
    }
    covers.sort_by_key(|image| std::cmp::Reverse(image_rank(image)));
    let images = covers
        .iter()
        .filter_map(|image| {
            let file_id = image.id.to_base16().ok()?;
            Some(format!(
                "{{\"url\":{},\"width\":{},\"height\":{}}}",
                json_string(&format!("https://i.scdn.co/image/{file_id}")),
                image.width,
                image.height
            ))
        })
        .collect::<Vec<_>>()
        .join(",");
    let artists = track
        .artists
        .iter()
        .map(|artist| format!("{{\"name\":{}}}", json_string(&artist.name)))
        .collect::<Vec<_>>()
        .join(",");

    Some(format!(
        "{{\"id\":{},\"name\":{},\"duration_ms\":{},\"album\":{{\"name\":{},\"images\":[{images}]}},\"artists\":[{artists}]}}",
        json_string(&id),
        json_string(&track.name),
        track.duration.max(0),
        json_string(&track.album.name)
    ))
}

/// Lists up to `limit` entries of a playlist starting at `offset`, through librespot. Spotify only gives
/// development mode Web API apps the tracks of the user's own playlists, librespot can read any playlist.
/// Stores JSON like a Web API playlist items page in json_out:
/// {"total": entries, "next_offset": offset to continue from or null, "next": null, "items": [{"track": {...}}]}.
/// Episodes, local files and tracks that can't be looked up are left out. Blocks, free the JSON with
/// fm_librespot_free_string.
#[no_mangle]
pub unsafe extern "C" fn fm_librespot_playlist_tracks(
    playlist_id: *const c_char,
    offset: u32,
    limit: u32,
    json_out: *mut *mut c_char,
    error_out: *mut *mut c_char,
) -> bool {
    let Some(state) = state() else {
        set_error(error_out, "librespot isn't initialised");
        return false;
    };
    let Some(playlist_id) = str_arg(playlist_id) else {
        set_error(error_out, "Missing playlist ID");
        return false;
    };
    let uri = match SpotifyId::from_base62(playlist_id) {
        Ok(id) => SpotifyUri::Playlist { user: None, id },
        Err(_) => {
            set_error(error_out, format!("Invalid playlist ID: {playlist_id}"));
            return false;
        }
    };
    let session = match state.session() {
        Ok((session, _)) => session,
        Err(error) => {
            set_error(error_out, error);
            return false;
        }
    };

    let result: Result<String, String> = state.runtime.block_on(async move {
        let playlist = Playlist::get(&session, &uri).await.map_err(|e| format!("Couldn't load the playlist: {e}"))?;
        let mut entries: Vec<SpotifyUri> = playlist.tracks().cloned().collect();
        if entries.is_empty() {
            // Mixes like Battle Mix are empty until played: Spotify builds them when the context is resolved.
            entries = context_tracks(&session, &format!("spotify:playlist:{playlist_id}")).await.unwrap_or_default();
        }
        Ok(tracks_page_json(&session, &entries, offset, limit).await)
    });

    match result {
        Ok(json) => {
            if !json_out.is_null() {
                *json_out = CString::new(json).unwrap_or_default().into_raw();
            }
            true
        }
        Err(error) => {
            set_error(error_out, error);
            false
        }
    }
}

/// Spotify's lyrics for a track URI, as the JSON its own apps get (lyrics.lines with startTimeMs and
/// words, lyrics.syncType LINE_SYNCED or UNSYNCED, and colors). Returns false with "No lyrics" in error_out
/// when Spotify has none. Blocks, free the JSON with fm_librespot_free_string.
#[no_mangle]
pub unsafe extern "C" fn fm_librespot_lyrics(track_uri: *const c_char, json_out: *mut *mut c_char, error_out: *mut *mut c_char) -> bool {
    let Some(state) = state() else {
        set_error(error_out, "librespot isn't initialised");
        return false;
    };
    let Some(id) = str_arg(track_uri).and_then(|uri| uri.strip_prefix("spotify:track:")).and_then(|id| SpotifyId::from_base62(id).ok()) else {
        set_error(error_out, "Not a track");
        return false;
    };
    let session = match state.session() {
        Ok((session, _)) => session,
        Err(error) => {
            set_error(error_out, error);
            return false;
        }
    };
    match state.runtime.block_on(session.spclient().get_lyrics(&id)) {
        Ok(bytes) if !bytes.is_empty() => {
            if !json_out.is_null() {
                *json_out = CString::new(String::from_utf8_lossy(&bytes).replace('\0', "")).unwrap_or_default().into_raw();
            }
            true
        }
        Ok(_) => {
            set_error(error_out, "No lyrics");
            false
        }
        Err(error) => {
            // Spotify answers 404 for tracks without lyrics.
            let message = error.to_string();
            set_error(error_out, if message.contains("404") || message.to_lowercase().contains("not found") { "No lyrics".to_string() } else { message });
            false
        }
    }
}

/// Tracks looked up per extended-metadata request. librespot allows 300 requests per 30 seconds to Spotify, shared
/// with playback, so one request per track would run out on long lists.
const TRACKS_PER_METADATA_REQUEST: usize = 50;

/// Looks up `limit` of `entries` from `offset`, in batches, as JSON shaped like a Web API playlist items page:
/// {"total", "next_offset" (or null), "next": null, "items": [{"track": {...}}]}.
async fn tracks_page_json(session: &Session, entries: &[SpotifyUri], offset: u32, limit: u32) -> String {
    use librespot::protocol::extended_metadata::{BatchedEntityRequest, EntityRequest, ExtensionQuery};
    use librespot::protocol::extension_kind::ExtensionKind;
    use protobuf::{EnumOrUnknown, Message};

    let total = entries.len();
    let start = (offset as usize).min(total);
    let end = start.saturating_add(limit.max(1) as usize).min(total);
    let uris: Vec<String> = entries[start..end]
        .iter()
        .filter(|entry| matches!(entry, SpotifyUri::Track { .. }))
        .filter_map(|entry| entry.to_uri().ok())
        .collect();

    let mut items = Vec::new();
    for chunk in uris.chunks(TRACKS_PER_METADATA_REQUEST) {
        let request = BatchedEntityRequest {
            entity_request: chunk
                .iter()
                .map(|uri| EntityRequest {
                    entity_uri: uri.clone(),
                    query: vec![ExtensionQuery { extension_kind: EnumOrUnknown::new(ExtensionKind::TRACK_V4), ..Default::default() }],
                    ..Default::default()
                })
                .collect(),
            ..Default::default()
        };
        let response = match session.spclient().get_extended_metadata(request).await {
            Ok(response) => response,
            Err(error) => {
                log::warn!("Couldn't look up {} tracks: {error}", chunk.len());
                continue;
            }
        };
        let mut found = std::collections::HashMap::new();
        for array in &response.extended_metadata {
            for data in &array.extension_data {
                let Some(any) = data.extension_data.as_ref() else { continue };
                let Ok(message) = librespot::protocol::metadata::Track::parse_from_bytes(&any.value) else { continue };
                let Ok(uri) = SpotifyUri::from_uri(&data.entity_uri) else { continue };
                if let Ok(track) = Track::parse(&message, &uri) {
                    found.insert(data.entity_uri.clone(), track);
                }
            }
        }
        // In the list's order; tracks Spotify has no metadata for are left out.
        for uri in chunk {
            if let Some(json) = found.get(uri).and_then(track_json) {
                items.push(format!("{{\"track\":{json}}}"));
            }
        }
    }

    let next_offset = if end < total { end.to_string() } else { "null".to_string() };
    format!("{{\"total\":{total},\"next_offset\":{next_offset},\"next\":null,\"items\":[{}]}}", items.join(","))
}

fn add_context_tracks(tracks: &mut Vec<SpotifyUri>, page: &librespot::protocol::context_page::ContextPage) {
    tracks.extend(
        page.tracks
            .iter()
            .filter_map(|track| SpotifyUri::from_uri(track.uri()).ok())
            .filter(|uri| matches!(uri, SpotifyUri::Track { .. })),
    );
}

/// The tracks of a context (a playlist Spotify builds when it's played, like Battle Mix),
/// through Spotify's context service.
async fn context_tracks(session: &Session, uri: &str) -> Result<Vec<SpotifyUri>, String> {
    let context = session.spclient().get_context(uri).await.map_err(|e| format!("Couldn't load {uri}: {e}"))?;
    let mut tracks = Vec::new();
    for page in &context.pages {
        add_context_tracks(&mut tracks, page);
        // A page either has its tracks, or only a URL to load them from; either can continue at next_page_url.
        let mut next = if page.tracks.is_empty() { page.page_url().to_string() } else { page.next_page_url().to_string() };
        while !next.is_empty() {
            let bytes = session.spclient().get_next_page(&next).await.map_err(|e| format!("Couldn't load {uri}: {e}"))?;
            let page: librespot::protocol::context_page::ContextPage =
                protobuf_json_mapping::parse_from_str(&String::from_utf8_lossy(&bytes)).map_err(|e| format!("Unreadable page of {uri}: {e}"))?;
            add_context_tracks(&mut tracks, &page);
            next = page.next_page_url().to_string();
        }
    }
    Ok(tracks)
}

/// Spotify's AI DJ plays as this context. Resolving it gives no tracks, only the URL of a DJ session.
const DJ_CONTEXT: &str = "spotify:playlist:37i9dQZF1EYkqdzj48dyYq";

/// A page of the AI DJ (lexicon-session-provider, what Spotify's apps use for it): a context JSON whose page holds
/// about five picks and a next_page_url to continue at. The DJ's commentary is on the tracks' metadata as SSML
/// (narration.intro.ssml before a track, narration.outro.ssml after it); Spotify's apps turn it into speech with
/// their own text to speech, its audio isn't part of the session. `page_url` NULL starts a session. Blocks, free
/// the JSON with fm_librespot_free_string.
#[no_mangle]
pub unsafe extern "C" fn fm_librespot_dj_session(page_url: *const c_char, json_out: *mut *mut c_char, error_out: *mut *mut c_char) -> bool {
    let Some(state) = state() else {
        set_error(error_out, "librespot isn't initialised");
        return false;
    };
    let session = match state.session() {
        Ok((session, _)) => session,
        Err(error) => {
            set_error(error_out, error);
            return false;
        }
    };
    let url = match str_arg(page_url) {
        Some(url) if !url.is_empty() => url.to_string(),
        _ => format!("hm://lexicon-session-provider/context-resolve/v2/session?contextUri={DJ_CONTEXT}"),
    };
    match state.runtime.block_on(session.spclient().get_next_page(&url)) {
        Ok(bytes) => {
            if !json_out.is_null() {
                *json_out = CString::new(String::from_utf8_lossy(&bytes).replace('\0', "")).unwrap_or_default().into_raw();
            }
            true
        }
        Err(error) => {
            set_error(error_out, format!("Couldn't start the DJ: {error}"));
            false
        }
    }
}

/// Track metadata for a JSON array of track URIs, looked up in batches, shaped like fm_librespot_playlist_tracks'
/// pages. Blocks, free the JSON with fm_librespot_free_string.
#[no_mangle]
pub unsafe extern "C" fn fm_librespot_tracks(uris_json: *const c_char, json_out: *mut *mut c_char, error_out: *mut *mut c_char) -> bool {
    let Some(state) = state() else {
        set_error(error_out, "librespot isn't initialised");
        return false;
    };
    let entries: Vec<SpotifyUri> = str_arg(uris_json)
        .unwrap_or("[]")
        .trim_matches(|c| c == '[' || c == ']')
        .split(',')
        .filter_map(|uri| SpotifyUri::from_uri(uri.trim().trim_matches('"')).ok())
        .collect();
    let session = match state.session() {
        Ok((session, _)) => session,
        Err(error) => {
            set_error(error_out, error);
            return false;
        }
    };
    let count = entries.len() as u32;
    let json = state.runtime.block_on(tracks_page_json(&session, &entries, 0, count.max(1)));
    if !json_out.is_null() {
        *json_out = CString::new(json).unwrap_or_default().into_raw();
    }
    true
}


/// Every playlist in the user's library (Your Library's "rootlist"), with Spotify's own playlists like Daily Mix,
/// Discover Weekly or Your Top Songs 2023 that the Web API leaves out for development mode apps. JSON array of
/// {"id", "name", "description", "owner", "image", "length"}. Folders are flattened. Blocks, free the JSON with
/// fm_librespot_free_string.
#[no_mangle]
pub unsafe extern "C" fn fm_librespot_rootlist(json_out: *mut *mut c_char, error_out: *mut *mut c_char) -> bool {
    use protobuf::Message;
    let Some(state) = state() else {
        set_error(error_out, "librespot isn't initialised");
        return false;
    };
    let session = match state.session() {
        Ok((session, _)) => session,
        Err(error) => {
            set_error(error_out, error);
            return false;
        }
    };
    let result: Result<String, String> = state.runtime.block_on(async {
        let bytes = session.spclient().get_rootlist(0, Some(1000)).await.map_err(|e| format!("Couldn't load Your Library: {e}"))?;
        let list = librespot::protocol::playlist4_external::SelectedListContent::parse_from_bytes(&bytes).map_err(|e| format!("Unreadable library: {e}"))?;
        let Some(contents) = list.contents.as_ref() else { return Ok("[]".to_string()) };
        let mut playlists = Vec::new();
        for (index, item) in contents.items.iter().enumerate() {
            let Some(id) = item.uri().strip_prefix("spotify:playlist:") else { continue };
            let meta = contents.meta_items.get(index);
            let attributes = meta.and_then(|meta| meta.attributes.as_ref());
            let image = attributes
                .and_then(|attributes| {
                    attributes
                        .picture_size
                        .iter()
                        .find(|size| size.target_name() == "large" || size.target_name() == "default")
                        .or(attributes.picture_size.first())
                        .map(|size| size.url().to_string())
                })
                .unwrap_or_default();
            playlists.push(format!(
                "{{\"id\":{},\"name\":{},\"description\":{},\"owner\":{},\"image\":{},\"length\":{}}}",
                json_string(id),
                json_string(attributes.map(|a| a.name()).unwrap_or("")),
                json_string(attributes.map(|a| a.description()).unwrap_or("")),
                json_string(meta.map(|m| m.owner_username()).unwrap_or("")),
                json_string(&image),
                meta.map(|m| m.length()).unwrap_or(0)
            ));
        }
        Ok(format!("[{}]", playlists.join(",")))
    });
    match result {
        Ok(json) => {
            if !json_out.is_null() {
                *json_out = CString::new(json).unwrap_or_default().into_raw();
            }
            true
        }
        Err(error) => {
            set_error(error_out, error);
            false
        }
    }
}

/// Splits a protobuf message into (field number, varint value, bytes of a length-delimited field). librespot's
/// Canvas definitions leave out the request and the response's list, so these are read and written by hand.
fn protobuf_fields(mut data: &[u8]) -> Vec<(u64, u64, &[u8])> {
    fn read_varint(data: &mut &[u8]) -> Option<u64> {
        let mut value = 0u64;
        for shift in (0..64).step_by(7) {
            let (&byte, rest) = data.split_first()?;
            *data = rest;
            value |= u64::from(byte & 0x7F) << shift;
            if byte & 0x80 == 0 {
                return Some(value);
            }
        }
        None
    }

    let mut fields = Vec::new();
    while let Some(key) = read_varint(&mut data) {
        let (field, wire_type) = (key >> 3, key & 7);
        match wire_type {
            0 => match read_varint(&mut data) {
                Some(value) => fields.push((field, value, &[][..])),
                None => break,
            },
            1 | 5 => {
                let length = if wire_type == 1 { 8 } else { 4 };
                if data.len() < length {
                    break;
                }
                data = &data[length..];
            }
            2 => {
                let Some(length) = read_varint(&mut data).map(|length| length as usize) else { break };
                if data.len() < length {
                    break;
                }
                let (value, rest) = data.split_at(length);
                fields.push((field, 0, value));
                data = rest;
            }
            _ => break,
        }
    }
    fields
}

/// A protobuf field holding `value`, for fields below 16 and values under 128 bytes.
fn protobuf_bytes_field(field: u8, value: &[u8]) -> Vec<u8> {
    let mut bytes = vec![field << 3 | 2, value.len() as u8];
    bytes.extend_from_slice(value);
    bytes
}

/// The address of a track's Canvas, the short looping clip Spotify shows instead of the cover. Returns false with
/// "No Canvas" in error_out when it has none. Blocks, free the URL with fm_librespot_free_string.
#[no_mangle]
pub unsafe extern "C" fn fm_librespot_canvas(track_uri: *const c_char, url_out: *mut *mut c_char, error_out: *mut *mut c_char) -> bool {
    const CANVAS_TYPE_VIDEO: u64 = 1;
    const CANVAS_TYPE_VIDEO_LOOPING_RANDOM: u64 = 3;

    let Some(state) = state() else {
        set_error(error_out, "librespot isn't initialised");
        return false;
    };
    let Some(uri) = str_arg(track_uri) else {
        set_error(error_out, "Not a track");
        return false;
    };
    let session = match state.session() {
        Ok((session, _)) => session,
        Err(error) => {
            set_error(error_out, error);
            return false;
        }
    };

    let mut headers = http::HeaderMap::new();
    headers.insert(http::header::CONTENT_TYPE, http::HeaderValue::from_static("application/x-protobuf"));
    let body = protobuf_bytes_field(1, &protobuf_bytes_field(1, uri.as_bytes()));
    let response = state.runtime.block_on(session.spclient().request(&http::Method::POST, "/canvaz-cache/v0/canvases", Some(headers), Some(&body)));
    let bytes = match response {
        Ok(bytes) => bytes,
        Err(error) => {
            set_error(error_out, format!("Couldn't look up the Canvas: {error}"));
            return false;
        }
    };

    for (field, _, canvas) in protobuf_fields(&bytes) {
        if field != 1 {
            continue;
        }
        let fields = protobuf_fields(canvas);
        let is_video = fields.iter().any(|(field, value, _)| *field == 4 && (CANVAS_TYPE_VIDEO..=CANVAS_TYPE_VIDEO_LOOPING_RANDOM).contains(value));
        let url = fields.iter().find(|(field, _, _)| *field == 2).map(|(_, _, url)| String::from_utf8_lossy(url).into_owned());
        if let (true, Some(url)) = (is_video, url) {
            if !url_out.is_null() {
                *url_out = CString::new(url).unwrap_or_default().into_raw();
            }
            return true;
        }
    }
    set_error(error_out, "No Canvas");
    false
}
