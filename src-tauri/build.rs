#[cfg(target_os = "macos")]
fn build_swiftui_glass_bridge() {
    use std::path::PathBuf;
    use std::process::Command;

    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let source = manifest_dir.join("native/ArcoGlassControls.swift");
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let library = out_dir.join("libArcoGlassControls.a");
    let arch = match std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
        Ok("aarch64") => "arm64",
        Ok("x86_64") => "x86_64",
        Ok(other) => panic!("unsupported macOS architecture for SwiftUI glass: {other}"),
        Err(error) => panic!("missing Cargo target architecture: {error}"),
    };
    let sdk = Command::new("xcrun")
        .args(["--sdk", "macosx", "--show-sdk-path"])
        .output()
        .expect("xcrun must be available to compile the SwiftUI glass bridge");
    assert!(sdk.status.success(), "xcrun could not locate the macOS SDK");
    let sdk = String::from_utf8(sdk.stdout)
        .expect("xcrun SDK path must be UTF-8")
        .trim()
        .to_string();
    let target = format!("{arch}-apple-macos14.6");
    let status = Command::new("xcrun")
        .arg("swiftc")
        .args(["-parse-as-library", "-emit-library", "-static"])
        .arg("-module-name")
        .arg("ArcoGlassControls")
        .arg("-target")
        .arg(&target)
        .arg("-sdk")
        .arg(&sdk)
        .arg(&source)
        .arg("-o")
        .arg(&library)
        .status()
        .expect("swiftc must be available to compile the SwiftUI glass bridge");
    assert!(status.success(), "SwiftUI glass bridge compilation failed");

    println!("cargo:rerun-if-changed={}", source.display());
    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=ArcoGlassControls");
    println!("cargo:rustc-link-lib=framework=SwiftUI");
    println!("cargo:rustc-link-lib=framework=AppKit");
    println!("cargo:rustc-link-lib=framework=Foundation");
}

fn main() {
    #[cfg(target_os = "macos")]
    build_swiftui_glass_bridge();
    tauri_build::build()
}
