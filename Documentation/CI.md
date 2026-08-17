# Continuous integration

`.github/workflows/ios.yml` runs on pull requests, pushes to `main`, and manual
dispatch.

## Runner and toolchain

- `runs-on: macos-26`
- Xcode is selected explicitly: `/Applications/Xcode_26.6.app`, falling back to
  the newest `Xcode_26*.app` on the image with a warning if that exact path is
  absent. GitHub moves point releases around between image refreshes; pinning
  the exact path *and* failing hard on it would break CI for reasons unrelated
  to the code, so the intent is pinned and the specifics are resolved.
- The workflow prints `xcodebuild -version` and `swift --version` into the job
  summary so a toolchain change is visible in the run itself.

## Destination

`Scripts/resolve-destination.sh` picks a simulator in this order:

1. `iPhone 17 Pro` on any iOS 26 runtime
2. any iPhone on an iOS 26 runtime
3. `generic/platform=iOS Simulator`

The resolved destination is written to the job summary.

## Stages

1. Environment information
2. Resolve package dependencies
3. Show relevant build settings
4. `build-for-testing`
5. `test-without-building`
6. Static validation (`Scripts/static-validation.sh`)
7. Upload `.xcresult` bundles on failure

Builds run with `CODE_SIGNING_ALLOWED=NO`, so no signing identity is needed.
`xcbeautify` is installed when available and the raw log is used otherwise —
a missing formatter must never fail a build.

## Static validation

`Scripts/static-validation.sh` catches the things a green build can still hide:

- tracked files over 3 MB (media fixtures must be generated, not committed)
- tracked build products
- placeholder UI or stubbed implementations in `Frames/`
- a missing or malformed string catalog
- missing app icon or accent colour assets

It exits non-zero on any of these, so the job fails.

## Reproducing locally

```bash
bash Scripts/resolve-destination.sh
bash Scripts/static-validation.sh
xcodebuild test -project Frames.xcodeproj -scheme Frames \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO
```
