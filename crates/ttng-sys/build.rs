//! Finds BearWare's TeamTalk 5 SDK for the target (`TTNG_SDK_DIR`, or the
//! repository's `sdk/<platform>` from `scripts/fetch-sdk.sh`), generates
//! bindings from its `TeamTalk.h`, and links its library.

use std::env;
use std::path::{Path, PathBuf};

fn main() {
    let os = env::var("CARGO_CFG_TARGET_OS").unwrap();
    let target = env::var("TARGET").unwrap();
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
    // iOS: BearWare's official library is "fat" (iPhone arm64 and the
    // Intel simulator in one file), which rustc can't bundle, so the
    // target's slice is taken out with lipo (the SDK itself is unchanged).
    // The SDK built from source (scripts/build-sdk-apple.sh) has one
    // library per slice instead, Apple silicon simulator included.
    let lib_dir = if platform == "ios" {
        let sim = target.ends_with("-sim");
        let slice = match arch.as_str() {
            "aarch64" if sim => "arm64-simulator",
            "aarch64" => "arm64",
            "x86_64" => "x86_64",
            _ => panic!("no iOS SDK library for {target}"),
        };
        let out = PathBuf::from(env::var("OUT_DIR").unwrap()).join("teamtalk-slice");
        std::fs::create_dir_all(&out).unwrap();
        let built = dll.join(format!("libTeamTalk5-{slice}.a"));
        println!("cargo:rerun-if-changed={}", built.display());
        if built.exists() {
            std::fs::copy(&built, out.join("libTeamTalk5.a")).expect("copying the SDK's library");
        } else {
            assert!(
                slice != "arm64-simulator",
                "BearWare's official iOS SDK has no Apple silicon simulator library: build the SDK from source (scripts/build-sdk-apple.sh) and set TTNG_SDK_DIR to sdk/ios-src"
            );
            let status = std::process::Command::new("lipo")
                .arg(lib_dir.join("libTeamTalk5.a"))
                .args(["-thin", slice, "-output"])
                .arg(out.join("libTeamTalk5.a"))
                .status()
                .expect("lipo (Xcode's command line tools) is needed to build for iOS");
            assert!(
                status.success(),
                "lipo couldn't take the {slice} slice out of libTeamTalk5.a"
            );
        }
        out
    } else {
        lib_dir
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
        // zlib (desktop sharing in the SDK), from the system.
        println!("cargo:rustc-link-lib=z");
    } else {
        println!("cargo:rustc-link-lib=dylib=TeamTalk5");
    }

    let mut builder = bindgen::Builder::default()
        .header(header.to_string_lossy())
        .clang_arg(format!("--target={}", clang_target(&target)))
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
    // Apple targets: clang needs the platform's SDK for system headers.
    if platform == "ios" || platform == "macos" {
        let sdk_name = match (
            platform,
            target.ends_with("-sim") || (platform == "ios" && arch == "x86_64"),
        ) {
            ("ios", true) => "iphonesimulator",
            ("ios", false) => "iphoneos",
            _ => "macosx",
        };
        if let Ok(out) = std::process::Command::new("xcrun")
            .args(["--sdk", sdk_name, "--show-sdk-path"])
            .output()
        {
            let path = String::from_utf8_lossy(&out.stdout).trim().to_owned();
            if !path.is_empty() {
                builder = builder.clang_arg(format!("-isysroot{path}"));
            }
        }
    }
    let bindings = builder.generate().expect("couldn't generate bindings from TeamTalk.h");
    bindings
        .write_to_file(PathBuf::from(env::var("OUT_DIR").unwrap()).join("bindings.rs"))
        .unwrap();
}

/// Rust's target name as clang wants it (clang has no "-sim" triples).
fn clang_target(target: &str) -> String {
    match target.strip_suffix("-sim") {
        Some(base) => {
            let min = env::var("IPHONEOS_DEPLOYMENT_TARGET").unwrap_or_else(|_| "17.0".into());
            format!("{}{min}-simulator", base.replace("aarch64", "arm64"))
        }
        None => target.to_owned(),
    }
}
