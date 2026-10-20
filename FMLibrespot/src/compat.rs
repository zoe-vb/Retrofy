//! Replacements for libSystem functions that Rust's std imports but iOS 6 doesn't have.
//! The app links these instead of the (missing) system versions, so it still launches on iOS 6.

use std::ffi::{c_int, c_long};
use std::sync::atomic::{AtomicU64, Ordering};

#[repr(C)]
pub struct Timespec {
    tv_sec: c_long,
    tv_nsec: c_long,
}

#[repr(C)]
struct Timeval {
    tv_sec: c_long,
    tv_usec: i32,
}

#[repr(C)]
struct MachTimebaseInfo {
    numer: u32,
    denom: u32,
}

extern "C" {
    fn mach_absolute_time() -> u64;
    fn mach_timebase_info(info: *mut MachTimebaseInfo) -> c_int;
    fn gettimeofday(tv: *mut Timeval, tz: *mut core::ffi::c_void) -> c_int;
    fn __error() -> *mut c_int;
}

const CLOCK_REALTIME: c_int = 0;
const CLOCK_MONOTONIC_RAW: c_int = 4;
const CLOCK_MONOTONIC_RAW_APPROX: c_int = 5;
const CLOCK_MONOTONIC: c_int = 6;
const CLOCK_UPTIME_RAW: c_int = 8;
const CLOCK_UPTIME_RAW_APPROX: c_int = 9;
const EINVAL: c_int = 22;

// numer in the high 32 bits, denom in the low 32 bits, 0 until first use.
static TIMEBASE: AtomicU64 = AtomicU64::new(0);

fn timebase() -> (u64, u64) {
    let mut cached = TIMEBASE.load(Ordering::Relaxed);
    if cached == 0 {
        let mut info = MachTimebaseInfo { numer: 0, denom: 0 };
        unsafe { mach_timebase_info(&mut info) };
        if info.denom == 0 {
            info = MachTimebaseInfo { numer: 1, denom: 1 };
        }
        cached = (u64::from(info.numer) << 32) | u64::from(info.denom);
        TIMEBASE.store(cached, Ordering::Relaxed);
    }
    (cached >> 32, cached & 0xffff_ffff)
}

/// `clock_gettime` only exists since iOS 10.
#[no_mangle]
#[allow(clashing_extern_declarations)]
pub unsafe extern "C" fn clock_gettime(clock_id: c_int, tp: *mut Timespec) -> c_int {
    if tp.is_null() {
        *__error() = EINVAL;
        return -1;
    }
    match clock_id {
        CLOCK_REALTIME => {
            let mut tv = Timeval { tv_sec: 0, tv_usec: 0 };
            if gettimeofday(&mut tv, core::ptr::null_mut()) != 0 {
                return -1;
            }
            (*tp).tv_sec = tv.tv_sec;
            (*tp).tv_nsec = tv.tv_usec as c_long * 1000;
            0
        }
        // mach_absolute_time doesn't advance during sleep, which is fine for measuring intervals.
        CLOCK_MONOTONIC | CLOCK_MONOTONIC_RAW | CLOCK_MONOTONIC_RAW_APPROX | CLOCK_UPTIME_RAW
        | CLOCK_UPTIME_RAW_APPROX => {
            let (numer, denom) = timebase();
            let nanos = (u128::from(mach_absolute_time()) * u128::from(numer) / u128::from(denom)) as u64;
            (*tp).tv_sec = (nanos / 1_000_000_000) as c_long;
            (*tp).tv_nsec = (nanos % 1_000_000_000) as c_long;
            0
        }
        _ => {
            *__error() = EINVAL;
            -1
        }
    }
}

extern "C" {
    fn arc4random_buf(buf: *mut core::ffi::c_void, nbytes: usize);
    fn sin(x: f64) -> f64;
    fn cos(x: f64) -> f64;
    fn pow(x: f64, y: f64) -> f64;
}

/// CommonCrypto's `CCRandomGenerateBytes` only exists since iOS 8. std uses it for random numbers.
#[no_mangle]
pub unsafe extern "C" fn CCRandomGenerateBytes(bytes: *mut core::ffi::c_void, count: usize) -> i32 {
    arc4random_buf(bytes, count);
    0 // kCCSuccess
}

#[repr(C)]
pub struct SinCos {
    sin: f64,
    cos: f64,
}

/// libm's `__sincos_stret` only exists since iOS 7, LLVM emits it for sin(x) and cos(x) of the same x.
/// black_box hides that both calls share x, otherwise LLVM would turn this back into a call to itself.
#[no_mangle]
pub extern "C" fn __sincos_stret(x: f64) -> SinCos {
    unsafe {
        SinCos {
            sin: sin(x),
            cos: cos(core::hint::black_box(x)),
        }
    }
}

/// libm's `__exp10` only exists since iOS 7. black_box keeps LLVM from turning pow(10, x) into exp10.
#[no_mangle]
pub extern "C" fn __exp10(x: f64) -> f64 {
    unsafe { pow(core::hint::black_box(10.0), x) }
}

/// 128 bit unsigned to double conversion, which iOS's 32 bit compiler runtime doesn't have.
#[no_mangle]
pub extern "C" fn __floatuntidf(a: u128) -> f64 {
    let high = (a >> 64) as u64;
    let low = a as u64;
    high as f64 * 18446744073709551616.0 + low as f64
}

/// 128 bit unsigned to float conversion, which iOS's 32 bit compiler runtime doesn't have either.
#[no_mangle]
pub extern "C" fn __floatuntisf(a: u128) -> f32 {
    __floatuntidf(a) as f32
}

/// `dirfd` is only a macro in older SDKs. Apple's DIR starts with the descriptor (`int __dd_fd`).
#[no_mangle]
pub unsafe extern "C" fn dirfd(dirp: *mut core::ffi::c_void) -> c_int {
    if dirp.is_null() {
        *__error() = EINVAL;
        return -1;
    }
    *(dirp as *const c_int)
}
