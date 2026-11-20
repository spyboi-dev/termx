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
builds it on a `macos-26` runner from the pinned Kernarium commit
(full `prepare.sh` + GPU prefix + kernel bundle + runtime-tree CMake
build) and uploads the device-slice framework as an artifact.
Download the artifact and copy `KRuntime_6_18_4K.framework` into
this directory, then re-run `../build.sh`. The build refuses to link
without it (see the preflight in `build.sh`).

Manual Mac route (Xcode, CMake 3.27+, Ninja, Meson, Python 3.11+,
and the dependencies from upstream `dependencies/README.md`):

```
git clone https://github.com/imxieyi/Kernarium
cd Kernarium
Kernarium/scripts/package-ios-frameworks.sh --sdk device
# default --runtimes all: builds both KRuntime_6_18_4K and
# KRuntime_Android_6_18_4K; output in .build/kernarium-xcframeworks/
```
