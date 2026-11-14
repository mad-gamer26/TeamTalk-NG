//! Raw bindings to BearWare's TeamTalk 5 SDK C API (`TeamTalk.h`), generated
//! at build time from the SDK that `scripts/fetch-sdk.sh` downloaded (the SDK
//! isn't in this repository). Everything here is `unsafe` and mirrors the C
//! header exactly; `ttng-core` is the safe layer.
#![allow(
    non_upper_case_globals,
    non_camel_case_types,
    non_snake_case,
    missing_debug_implementations,
    clippy::all
)]

include!(concat!(env!("OUT_DIR"), "/bindings.rs"));
