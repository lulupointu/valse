//! Small helpers around objc2 / CoreFoundation used by the AVFoundation code paths.
use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2_core_foundation::CFString;
use objc2_core_media::CMTime;
use objc2_foundation::{NSDictionary, NSNumber, NSString, NSURL};

pub fn ns(s: &str) -> Retained<NSString> {
    NSString::from_str(s)
}

/// Toll-free bridge a CFString constant to NSString.
pub fn cf_ns(s: &CFString) -> &NSString {
    unsafe { &*(s as *const CFString as *const NSString) }
}

pub fn num_u32(v: u32) -> Retained<NSNumber> {
    NSNumber::new_u32(v)
}
pub fn num_i64(v: i64) -> Retained<NSNumber> {
    NSNumber::new_i64(v)
}
pub fn num_f64(v: f64) -> Retained<NSNumber> {
    NSNumber::new_f64(v)
}
pub fn num_bool(v: bool) -> Retained<NSNumber> {
    NSNumber::new_bool(v)
}

/// Build an NSDictionary<NSString, AnyObject> from (key, value) pairs.
pub fn dict(pairs: &[(&NSString, &AnyObject)]) -> Retained<NSDictionary<NSString, AnyObject>> {
    let keys: Vec<&NSString> = pairs.iter().map(|p| p.0).collect();
    let vals: Vec<&AnyObject> = pairs.iter().map(|p| p.1).collect();
    NSDictionary::from_slices(&keys, &vals)
}

pub fn file_url(path: &str) -> Retained<NSURL> {
    let abs = std::fs::canonicalize(path)
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| path.to_string());
    NSURL::fileURLWithPath(&ns(&abs))
}

pub fn cmtime(seconds: f64) -> CMTime {
    unsafe { CMTime::with_seconds(seconds, 90000) }
}

pub fn secs(t: CMTime) -> f64 {
    unsafe { t.seconds() }
}

/// Wrapper to move CF/ObjC objects across threads. CVPixelBuffer / IOSurface are thread-safe
/// reference-counted objects; AVFoundation reader objects are used from a single thread at a time.
pub struct SendBox<T>(pub T);
unsafe impl<T> Send for SendBox<T> {}
unsafe impl<T> Sync for SendBox<T> {}
