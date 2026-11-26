//! On-device remote pairing for Built-in StikJIT (iOS 27 and later).
//!
//! TermX plays the computer in iOS 27's device-initiated pairing: it
//! listens on a TCP port, the app advertises that port as a
//! `_remotepairing-pairable-host._tcp` Bonjour service (see
//! TXOnDevicePairing.m), the user taps "Pair with TermX" under
//! Settings > Privacy & Security > Developer Mode and types the PIN
//! the app shows. The result is the RPPairing plist StikJIT reads,
//! returned here as bytes.
//!
//! The protocol is idevice's `PairableHost` (MIT, jkcoxson/idevice,
//! `remote_pairing` feature only). This crate only binds the
//! listener, runs the pairing, and hands the pairing bytes back to
//! the app. It does no Apple ID sign-in and installs no profiles.
//!
//! The C interface is termx/src/TXRPPairing.h. The host name is
//! shown on the iPhone as "Pair with TermX"; the host identifier is
//! derived from it, and the device replaces its record for that
//! identifier on each new pairing, so a fresh identity per run is
//! intended.
// SPDX-License-Identifier: GPL-2.0-or-later

use std::ffi::{CStr, CString, c_char, c_void};
use std::net::{Ipv4Addr, TcpListener};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use idevice::remote_pairing::{PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket};
use tokio::sync::Notify;
use tokio::task::JoinSet;

/// iOS shows the host as a computer; keep this a Mac model identifier.
const HOST_MODEL: &str = "Mac17,7";

pub struct TxRPPairing {
    port: u16,
    service_name: CString,
    txt: Vec<(CString, CString)>,
    listener: Mutex<Option<TcpListener>>,
    identity: Mutex<Option<(RpPairingFile, PairableHostInfo)>>,
    cancelled: AtomicBool,
    cancel: Notify,
}

pub type TxRPPairingPinCallback = Option<extern "C" fn(pin: *const c_char, context: *mut c_void)>;

/// The caller's PIN callback plus its context. The context is only
/// handed back to the callback, on the accepting thread.
#[derive(Clone, Copy)]
struct PinTarget {
    callback: TxRPPairingPinCallback,
    context: *mut c_void,
}
// The context is only handed back to the caller's callback, on the accepting thread.
unsafe impl Send for PinTarget {}
unsafe impl Sync for PinTarget {}

impl PinTarget {
    fn show(&self, pin: String) {
        if let (Some(callback), Ok(pin)) = (self.callback, CString::new(pin)) {
            callback(pin.as_ptr(), self.context);
        }
    }
}

enum Failure {
    Cancelled,
    Error(String),
}

fn set_error(out: *mut *mut c_char, message: impl Into<Vec<u8>>) {
    if !out.is_null() {
        unsafe { *out = CString::new(message).unwrap_or_default().into_raw() };
    }
}

/// Generates a fresh host identity and binds a TCP listener on all
/// IPv4 interfaces. Returns NULL on failure, with `*error` set (free
/// it with `tx_rppairing_string_free`).
///
/// # Safety
/// `name` must be a valid NUL-terminated string. `error` must be NULL or writable.
#[no_mangle]
pub unsafe extern "C" fn tx_rppairing_new(name: *const c_char, error: *mut *mut c_char) -> *mut TxRPPairing {
    if name.is_null() {
        set_error(error, "missing host name");
        return ptr::null_mut();
    }
    let name = match unsafe { CStr::from_ptr(name) }.to_str() {
        Ok(name) if !name.is_empty() => name.to_string(),
        _ => {
            set_error(error, "invalid host name");
            return ptr::null_mut();
        }
    };

    let listener = match TcpListener::bind((Ipv4Addr::UNSPECIFIED, 0)) {
        Ok(listener) => listener,
        Err(e) => {
            set_error(error, format!("could not open the pairing port: {e}"));
            return ptr::null_mut();
        }
    };
    let port = match listener
        .local_addr()
        .and_then(|addr| listener.set_nonblocking(true).map(|_| addr.port()))
    {
        Ok(port) => port,
        Err(e) => {
            set_error(error, format!("could not open the pairing port: {e}"));
            return ptr::null_mut();
        }
    };

    let pairing_file = RpPairingFile::generate(&name);
    let host_info = PairableHostInfo::generate(&name, HOST_MODEL);
    let identifier = pairing_file.identifier.clone();
    let txt = host_info
        .mdns_txt_records(&identifier)
        .into_iter()
        .filter_map(|(k, v)| Some((CString::new(k).ok()?, CString::new(v).ok()?)))
        .collect();

    Box::into_raw(Box::new(TxRPPairing {
        port,
        service_name: CString::new(identifier).unwrap_or_default(),
        txt,
        listener: Mutex::new(Some(listener)),
        identity: Mutex::new(Some((pairing_file, host_info))),
        cancelled: AtomicBool::new(false),
        cancel: Notify::new(),
    }))
}

/// # Safety
/// `session` must be a live pointer from `tx_rppairing_new`.
#[no_mangle]
pub unsafe extern "C" fn tx_rppairing_port(session: *const TxRPPairing) -> u16 {
    unsafe { &*session }.port
}

/// The Bonjour service instance name to publish. Owned by the session.
///
/// # Safety
/// `session` must be a live pointer from `tx_rppairing_new`.
#[no_mangle]
pub unsafe extern "C" fn tx_rppairing_service_name(session: *const TxRPPairing) -> *const c_char {
    unsafe { &*session }.service_name.as_ptr()
}

/// # Safety
/// `session` must be a live pointer from `tx_rppairing_new`.
#[no_mangle]
pub unsafe extern "C" fn tx_rppairing_txt_count(session: *const TxRPPairing) -> usize {
    unsafe { &*session }.txt.len()
}

/// TXT record key at `index`, or NULL past the end. Owned by the session.
///
/// # Safety
/// `session` must be a live pointer from `tx_rppairing_new`.
#[no_mangle]
pub unsafe extern "C" fn tx_rppairing_txt_key(session: *const TxRPPairing, index: usize) -> *const c_char {
    unsafe { &*session }.txt.get(index).map_or(ptr::null(), |(k, _)| k.as_ptr())
}

/// TXT record value at `index`, or NULL past the end. Owned by the session.
///
/// # Safety
/// `session` must be a live pointer from `tx_rppairing_new`.
#[no_mangle]
pub unsafe extern "C" fn tx_rppairing_txt_value(session: *const TxRPPairing, index: usize) -> *const c_char {
    unsafe { &*session }.txt.get(index).map_or(ptr::null(), |(_, v)| v.as_ptr())
}

/// Blocks until a device pairs, pairing fails, or
/// `tx_rppairing_cancel` is called. `pin_callback` runs on this
/// thread with the 6-digit code to show.
///
/// Returns 0 on success (`*out_plist`/`*out_len` hold the RPPairing
/// plist, free with `tx_rppairing_bytes_free`; `*out_device_name`
/// the device's name), 1 on failure (`*error` set), 2 when
/// cancelled. Call at most once per session.
///
/// # Safety
/// `session` must be a live pointer from `tx_rppairing_new`; the out
/// pointers must be NULL or writable.
#[no_mangle]
pub unsafe extern "C" fn tx_rppairing_accept(
    session: *const TxRPPairing,
    pin_callback: TxRPPairingPinCallback,
    pin_context: *mut c_void,
    out_plist: *mut *mut u8,
    out_len: *mut usize,
    out_device_name: *mut *mut c_char,
    error: *mut *mut c_char,
) -> i32 {
    let session = unsafe { &*session };
    let listener = session.listener.lock().ok().and_then(|mut l| l.take());
    let identity = session.identity.lock().ok().and_then(|mut i| i.take());
    let (Some(listener), Some((pairing_file, host_info))) = (listener, identity) else {
        set_error(error, "this pairing session has already been used");
        return 1;
    };

    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(e) => {
            set_error(error, format!("could not start the pairing runtime: {e}"));
            return 1;
        }
    };
    let target = PinTarget { callback: pin_callback, context: pin_context };

    match runtime.block_on(run_accept(session, listener, pairing_file, host_info, target)) {
        Ok((file, device_name)) => {
            let bytes = file.to_bytes().into_boxed_slice();
            if !out_len.is_null() {
                unsafe { *out_len = bytes.len() };
            }
            if !out_plist.is_null() {
                unsafe { *out_plist = Box::into_raw(bytes) as *mut u8 };
            }
            if !out_device_name.is_null() {
                unsafe { *out_device_name = CString::new(device_name).unwrap_or_default().into_raw() };
            }
            0
        }
        Err(Failure::Cancelled) => 2,
        Err(Failure::Error(message)) => {
            set_error(error, message);
            1
        }
    }
}

async fn run_attempt(
    stream: tokio::net::TcpStream,
    mut file: RpPairingFile,
    host_info: PairableHostInfo,
    target: PinTarget,
    pin_shown: Arc<AtomicBool>,
) -> Result<(RpPairingFile, String), idevice::IdeviceError> {
    let mut host = PairableHost::new(RpPairingSocket::new_device(stream), host_info);
    let peer = host
        .accept(&mut file, |pin| {
            pin_shown.store(true, Ordering::SeqCst);
            target.show(pin);
            async {}
        })
        .await?;
    Ok((file, peer.name))
}

async fn run_accept(
    session: &TxRPPairing,
    listener: TcpListener,
    pairing_file: RpPairingFile,
    host_info: PairableHostInfo,
    target: PinTarget,
) -> Result<(RpPairingFile, String), Failure> {
    let listener = tokio::net::TcpListener::from_std(listener)
        .map_err(|e| Failure::Error(format!("could not listen for the device: {e}")))?;
    let pin_shown = Arc::new(AtomicBool::new(false));

    // Every connection is served at once, so one that stays open
    // without speaking cannot keep the device from reaching TermX.
    let pair = async {
        let mut attempts = JoinSet::new();
        loop {
            tokio::select! {
                connection = listener.accept() => {
                    let (stream, _) = connection
                        .map_err(|e| Failure::Error(format!("could not accept the device's connection: {e}")))?;
                    attempts.spawn(run_attempt(stream, pairing_file.clone(), host_info.clone(), target, pin_shown.clone()));
                }
                Some(done) = attempts.join_next() => match done {
                    Ok(Ok(paired)) => return Ok(paired),
                    // Failing before the PIN step means it was not the
                    // device's pairing attempt; keep listening.
                    _ if !pin_shown.load(Ordering::SeqCst) => continue,
                    Ok(Err(e)) => return Err(Failure::Error(format!("pairing failed: {e}"))),
                    Err(e) => return Err(Failure::Error(format!("pairing failed: {e}"))),
                },
            }
        }
    };

    if session.cancelled.load(Ordering::SeqCst) {
        return Err(Failure::Cancelled);
    }
    tokio::select! {
        biased;
        _ = session.cancel.notified() => Err(Failure::Cancelled),
        result = pair => result,
    }
}

/// Ends a running or future `tx_rppairing_accept` with result 2.
/// Safe from any thread, any number of times.
///
/// # Safety
/// `session` must be a live pointer from `tx_rppairing_new`.
#[no_mangle]
pub unsafe extern "C" fn tx_rppairing_cancel(session: *const TxRPPairing) {
    let session = unsafe { &*session };
    session.cancelled.store(true, Ordering::SeqCst);
    session.cancel.notify_waiters();
}

/// # Safety
/// `session` must be NULL or a pointer from `tx_rppairing_new`
/// whose accept, if any, has returned.
#[no_mangle]
pub unsafe extern "C" fn tx_rppairing_free(session: *mut TxRPPairing) {
    if !session.is_null() {
        drop(unsafe { Box::from_raw(session) });
    }
}

/// # Safety
/// `bytes`/`len` must come from `tx_rppairing_accept`, or `bytes` be NULL.
#[no_mangle]
pub unsafe extern "C" fn tx_rppairing_bytes_free(bytes: *mut u8, len: usize) {
    if !bytes.is_null() {
        drop(unsafe { Box::from_raw(std::slice::from_raw_parts_mut(bytes, len)) });
    }
}

/// # Safety
/// `string` must come from this crate, or be NULL.
#[no_mangle]
pub unsafe extern "C" fn tx_rppairing_string_free(string: *mut c_char) {
    if !string.is_null() {
        drop(unsafe { CString::from_raw(string) });
    }
}
