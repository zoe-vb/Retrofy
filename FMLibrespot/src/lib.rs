//! Rust bridge between FoxMusic and librespot, built for armv7s / iOS 6.
//! `fm_librespot_self_test` exercises the parts of std librespot leans on: threads,
//! thread locals, time, heap, sync and formatting. The player API lives in player.rs.

mod audio;
mod compat;
mod http;
mod player;
mod webapi_login;

use std::cell::Cell;
use std::ffi::{c_char, CString};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

thread_local! {
    static COUNTER: Cell<u32> = const { Cell::new(0) };
}

/// Runs a small self test and returns a description, free it with `fm_librespot_free_string`.
#[no_mangle]
pub extern "C" fn fm_librespot_self_test() -> *mut c_char {
    let start = Instant::now();
    let shared = Arc::new(Mutex::new(Vec::new()));
    let (tx, rx) = mpsc::channel();

    let workers: Vec<_> = (0..4u32)
        .map(|i| {
            let shared = Arc::clone(&shared);
            let tx = tx.clone();
            thread::Builder::new()
                .name(format!("fm-worker-{i}"))
                .spawn(move || {
                    COUNTER.with(|c| c.set(c.get() + i + 1));
                    let local = COUNTER.with(|c| c.get());
                    shared.lock().unwrap().push(local);
                    thread::sleep(Duration::from_millis(10));
                    tx.send(local).unwrap();
                })
                .expect("spawn")
        })
        .collect();
    drop(tx);
    for w in workers {
        w.join().unwrap();
    }
    let received: u32 = rx.iter().sum();
    let unix = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);

    let report = format!(
        "rust ok: threads={} sum={} unix={} elapsed={:?}",
        shared.lock().unwrap().len(),
        received,
        unix,
        start.elapsed()
    );
    CString::new(report).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn fm_librespot_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)) };
    }
}
