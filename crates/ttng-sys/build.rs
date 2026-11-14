//! Finds BearWare's TeamTalk 5 SDK for the target (`TTNG_SDK_DIR`, or the
//! repository's `sdk/<platform>` from `scripts/fetch-sdk.sh`), generates
//! bindings from its `TeamTalk.h`, and links its library.

use std::env;
use std::path::{Path, PathBuf};

fn main() {
    let os = env::var("CARGO_CFG_TARGET_OS").unwrap();
    let arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap();
    let platform = match os.as_str() {
        "linux" => "linux",
        "android" => "android",
        "ios" => "ios",
        "macos" => "macos",
        "windows" => "windows",
        other => panic!("TeamTalk NG doesn't build for {other}"),
    };
    println!("cargo:rerun-if-env-changed=TTNG_SDK_DIR");
    let sdk = env::var_os("TTNG_SDK_DIR").map(PathBuf::from).unwrap_or_else(|| {
        let root = Path::new(&env::var("CARGO_MANIFEST_DIR").unwrap()).join("../..");
        root.join("sdk").join(platform)
    });
    let dll = sdk.join("Library/TeamTalk_DLL");
    let header = dll.join("TeamTalk.h");
    if !header.exists() {
        panic!(
            "BearWare's TeamTalk SDK isn't at {}. Run scripts/fetch-sdk.sh {platform} (or set TTNG_SDK_DIR).",
            sdk.display()
        );
    }
    println!("cargo:rerun-if-changed={}", header.display());

    // The library's folder: per ABI on Android.
    let lib_dir = if platform == "android" {
        let abi = match arch.as_str() {
            "aarch64" => "arm64-v8a",
            "arm" => "armeabi-v7a",
            "x86_64" => "x86_64",
            "x86" => "x86",
            other => panic!("no Android SDK library for {other}"),
        };
        dll.join(abi)
    } else {
        dll.clone()
    };
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:lib_dir={}", lib_dir.display());
    println!("cargo:sdk_dir={}", sdk.display());
    if platform == "ios" {
        // A static library, with the system frameworks it uses.
        println!("cargo:rustc-link-lib=static=TeamTalk5");
        for f in [
            "AVFoundation",
            "AudioToolbox",
            "CoreAudio",
            "CoreMedia",
            "CoreVideo",
            "Foundation",
            "Security",
            "SystemConfiguration",
        ] {
            println!("cargo:rustc-link-lib=framework={f}");
        }
        println!("cargo:rustc-link-lib=c++");
    } else {
        println!("cargo:rustc-link-lib=dylib=TeamTalk5");
    }

    let target = env::var("TARGET").unwrap();
    let mut builder = bindgen::Builder::default()
        .header(header.to_string_lossy())
        .clang_arg(format!("--target={target}"))
        .allowlist_function("TT_.*")
        .allowlist_type(".*")
        .allowlist_var(".*")
        .default_enum_style(bindgen::EnumVariation::Consts)
        .derive_default(true)
        .derive_debug(false)
        .layout_tests(false)
        .generate_comments(false)
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()));
    if platform == "windows" {
        builder = builder.clang_arg("-DWIN32");
    }
    let bindings = builder.generate().expect("couldn't generate bindings from TeamTalk.h");
    bindings
        .write_to_file(PathBuf::from(env::var("OUT_DIR").unwrap()).join("bindings.rs"))
        .unwrap();
}
