extern crate pkg_config;

fn get_target() -> String {
    std::env::var("TARGET").unwrap()
}
fn main() {
    // FoxMusic patch: iOS targets (*-apple-ios) don't contain "darwin" either. dns_sd is part of
    // libSystem on every Apple platform, only other systems need Avahi's compatibility library.
    if !get_target().contains("darwin") && !get_target().contains("apple") {
        pkg_config::find_library("avahi-compat-libdns_sd").unwrap();
    }
}
