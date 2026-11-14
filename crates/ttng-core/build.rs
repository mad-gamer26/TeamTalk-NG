//! On Linux, lets tests and tools find the SDK's shared library where
//! `ttng-sys` found it (no LD_LIBRARY_PATH needed).
fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux")
        && let Ok(dir) = std::env::var("DEP_TEAMTALK5_LIB_DIR")
    {
        println!("cargo:rustc-link-arg=-Wl,-rpath,{dir}");
    }
}
