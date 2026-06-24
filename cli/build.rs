use std::env;
use std::fs;
use std::path::Path;

fn main() {
    let out_dir = env::var("OUT_DIR").unwrap();
    let dest_path = Path::new(&out_dir).join("version.rs");

    // CARGO_PKG_VERSION is resolved by Cargo from workspace.package.version
    let version = env::var("CARGO_PKG_VERSION").unwrap_or_else(|_| "0.0.0".to_string());

    let content = format!("pub const GDAPI_VERSION: &str = \"{}\";", version);
    fs::write(&dest_path, content).unwrap();

    // Re-run if the workspace Cargo.toml changes (version source)
    println!("cargo:rerun-if-changed=../Cargo.toml");
}
