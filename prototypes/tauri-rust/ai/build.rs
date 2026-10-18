// whisper.cpp (ggml-metal) uses `@available(...)` checks, which need compiler-rt's
// `__isPlatformVersionAtLeast`; rustc links with -nodefaultlibs so add clang_rt explicitly.
fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        if let Ok(out) = std::process::Command::new("clang").arg("--print-runtime-dir").output() {
            let dir = String::from_utf8_lossy(&out.stdout).trim().to_string();
            println!("cargo:rustc-link-search=native={dir}");
            println!("cargo:rustc-link-lib=static=clang_rt.osx");
        }
    }
}
