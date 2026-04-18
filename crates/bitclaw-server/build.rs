fn main() {
    println!("cargo:rustc-link-lib=static=agent_rt");
    println!("cargo:rustc-link-search=native=zig/zig-out/lib");
}
