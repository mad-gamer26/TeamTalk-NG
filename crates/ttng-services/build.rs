//! On Linux, lets the tests find the SDK's library (they use the core). The
//! core's DEP_ variable doesn't reach a crate that only tests with it, so
//! the SDK is found the way ttng-sys finds it.
fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("linux") {
        return;
    }
    println!("cargo:rerun-if-env-changed=TTNG_SDK_DIR");
    let sdk = std::env::var("TTNG_SDK_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../sdk/linux"));
    let lib = sdk.join("Library/TeamTalk_DLL");
    println!("cargo:rustc-link-arg-tests=-Wl,-rpath,{}", lib.display());
}
