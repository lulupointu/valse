pub mod audio;
pub mod av;
pub mod player;
pub mod present;
pub mod compositor;
pub mod decode;
pub mod export;
pub mod gpu;
pub mod source;

/// Emit one benchmark metric line in the shared JSON format.
pub fn metric_line(metric: &str, value: f64, unit: &str) -> String {
    format!("{{\"stack\":\"tauri-rust\",\"metric\":\"{metric}\",\"value\":{},\"unit\":\"{unit}\"}}", round3(value))
}
fn round3(v: f64) -> f64 {
    (v * 1000.0).round() / 1000.0
}
