# termx/rppairing — on-device remote pairing library

A small Rust static library (`libtx_rppairing.a`) wrapping idevice's
`PairableHost` (MIT, jkcoxson/idevice, `remote_pairing` feature only).
TermX plays the computer in iOS 27's device-initiated pairing: it
listens on a TCP port, the app advertises that port as a
`_remotepairing-pairable-host._tcp` Bonjour service
(`TXOnDevicePairing`), the user taps "Pair with TermX" under
Settings > Privacy & Security > Developer Mode and types the PIN
the app shows. The result is the RPPairing plist StikJIT reads, as
bytes.

Pairing only: no Apple ID sign-in, no profile install, no tunnel.
The C interface is `termx/src/TXRPPairing.h`.

## Build (Mac runner)

```sh
./build.sh   # rustup target aarch64-apple-ios, cargo build --release
```

That copies the library to `termx/rppairing-artifact/libtx_rppairing.a`,
where `termx/build.sh` links it when present. Without the artifact
the host app still builds: the C functions are weak imports and
on-device pairing reports itself missing, leaving the pairing-file
import as the only path.

CI builds it in `.github/workflows/build-rppairing.yml` (manual run,
or on pushes touching this crate). The artifact name is
`libtx_rppairing-a`.

## Reproducibility

Pin the versions in `Cargo.toml` (`idevice =0.1.68`). After the
first CI run, commit the generated `Cargo.lock` so later builds are
`--locked` reproducible.
