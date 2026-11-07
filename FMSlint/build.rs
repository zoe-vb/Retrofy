fn main() {
    // Puts the font in the library, the app can't count on reading iOS 6's own.
    let config = slint_build::CompilerConfiguration::new()
        .embed_resources(slint_build::EmbedResourcesKind::EmbedFiles);
    slint_build::compile_with_config("ui/nowplaying.slint", config).unwrap();
}
