# Experimental native binaries

These binaries were generated from the Rust sources and lockfile whose hashes
are listed in `SOURCE_SHA256SUMS`. `SHA256SUMS` records the output hashes.
They were rebuilt from `decoder-source.tar.gz` using its `rebuild.sh` with
Rust 1.90.0, Android NDK 28.2.13676358 (API 24), and Xcode 27.0 / iOS SDK
27.0. The script uses Cargo's `--locked --offline` options, remaps local paths,
and normalizes the iOS install names with `install_name_tool`.

`decoder-source.tar.gz` contains the corresponding Rust decoder source, pinned
Cargo lockfile and vendored crate sources, including their licenses. Extract
it and read its `README.txt` for build requirements and instructions. All six
targets were built from this archive offline with an empty Cargo package cache.
The current build has not been independently reproduced. Earlier Android
outputs matched across two local builds while iOS outputs differed; those
results do not establish reproducibility of the current files or device behavior.

The package hook selects one bundled file per supported platform, SDK and
architecture. Android 64-bit binaries have 16 KiB segment alignment. The
arm64 iOS Simulator binary has deployment target iOS 14.0; device and x64
simulator binaries record iOS 10.0. The Flutter camera dependency imposes its
own minimum platform requirements.

Before release, review the dependency notices and test the rebuilt artifacts on
the actual target devices and simulator configurations.
