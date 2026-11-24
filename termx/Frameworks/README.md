# Frameworks

The GPU frameworks the Kernarium runtime loads — `KosmicKrisp`,
`MesaEGL`, `MesaGallium` — extracted from Andarium's release IPA
(see `../vendor/` in the previous KTerm tree; the same three are used
by both runtime flavours).

## The missing piece: KRuntime_6_18_4K.framework

The Linux runtime framework is **not here**, and it is not in any
Kernarium release or in the Andarium IPA (that one carries the Android
flavour, `KRuntime_Android_6_18_4K`, only). It cannot be built on this
Linux VM: upstream's CMake refuses non-Apple hosts
(`CMakeLists.txt:46-48`) and the build needs Xcode, the Metal
toolchain, Swift/SPM and codesigning.

The supported way to get it is CI: `.github/workflows/build-framework.yml`
builds it on an `xcode-27` runner from the pinned Kernarium commit
(full `prepare.sh` + GPU prefix + kernel bundle + runtime-tree CMake
build) and uploads the device-slice framework as an artifact.
Download the artifact and copy `KRuntime_6_18_4K.framework` into
this directory, then re-run `../build.sh`. The build refuses to link
without it (see the preflight in `build.sh`).

## Provenance of the framework in this directory

The framework is **not in git** (53 MB; see `.gitignore`). This is
the copy it was built from, so a rebuild from the same CI run
reproduces it:

- Upstream Kernarium commit: `fbe12ee72d195f0241c4fc24090a98b259026604`
  (pinned in `.github/workflows/build-framework.yml`)
- Runtime API version: 43 (`kernarium_runtime_get_api_v28`)
- Framework binary SHA-256:
  `21a0e09ee5fa282ad82636bbffa4cf82d535028b459b078ee83b12cd90dadabd`
  (53,621,616 bytes)
- The app bakes this hash in at build time (`-DTERMX_FRAMEWORK_SHA256`)
  and the About screen shows its first 12 chars, so a device log
  always identifies the framework it ran. If this hash changes, the
  framework was rebuilt from a different upstream commit or CI run —
  update this file and check the runtime still boots before shipping.

Manual Mac route (Xcode, CMake 3.27+, Ninja, Meson, Python 3.11+,
and the dependencies from upstream `dependencies/README.md`):

```
git clone https://github.com/imxieyi/Kernarium
cd Kernarium
Kernarium/scripts/package-ios-frameworks.sh --sdk device
# default --runtimes all: builds both KRuntime_6_18_4K and
# KRuntime_Android_6_18_4K; output in .build/kernarium-xcframeworks/
```
