# Insta360 Ace Pro 2 → iPad direct Wi-Fi live preview: feasibility report

Status date: 2026-11-22. Scope: Step 1 of the camera integration requirement (protocol investigation), plus what the
implementation in this repository does about each finding.

## 1. Summary

| Question | Answer | Confidence |
| --- | --- | --- |
| Does the official Insta360 **iOS** SDK support the Ace Pro 2? | **No.** Insta360's own docs list the ACE-series iOS SDK as "Planned". | Verified (primary source) |
| Does the official **Android** SDK support the ACE series? | Yes (Android SDK V2.x, shared with the X and GO series), including raw preview stream access. | Verified for "ACE series"; the exact model list comes from a search snippet of insta360.com, which refused automated access |
| Does the Ace Pro 2 expose a local live-preview stream on its own Wi-Fi? | **Very likely yes**, via an undocumented TCP protocol on `192.168.42.1:6666` used by Insta360's own apps. | Documented independently by 4+ open-source projects; one (ace-studio) implements Wi-Fi live view for the Ace Pro 2; **not yet verified on hardware by this project** |
| Can an iPad app use it without the official SDK? | Yes, technically: plain TCP plus H.264/H.265 decoding in VideoToolbox. Implemented here and tested against a protocol-accurate mock camera. | Implementation verified against the mock; camera behaviour unverified |
| Can the app join the camera Wi-Fi by itself? | Only with the user's confirmation (NEHotspotConfiguration system prompt), and only with the Hotspot Configuration entitlement. Silent switching is not possible. Manual joining in Settings always works. | Verified (Apple SDK headers / docs) |

**Recommendation:** proceed with the direct Wi-Fi route, gated by a 15-minute hardware check with `ace-probe` on a Mac
(section 9). Nothing in the remaining risks requires changing the camera yet. The prerecorded-video and synthetic
sources let analysis development continue regardless of the result.

## 2. Official SDK situation

* **iOS SDK** (github.com/Insta360Develop/iOS-SDK, docs `sdk/x-ace-go/ios/guide.md`): supported cameras are
  X6, X5, X4 Air, X4, X3, X2, ONE X, ONE R, ONE RS, ONE RS 1-Inch. The ACE overview page states: *"The ACE series
  currently provides an Android SDK … iOS and Desktop are planned"*, with the iOS SDK marked "🕒 Planned"
  (Insta360-Developer_Docs, last updated 2026-11-09).
* **Android SDK V2.x** covers X, ACE and GO with one API. Relevant documented facts:
  * Wi-Fi gives low latency and supports live preview; a BLE-only connection does not carry the preview stream.
  * Wi-Fi credentials can be read over BLE (`getWifiData()`), then the phone joins the camera hotspot.
  * Raw-stream mode: `onStreamDataNotify(PreviewStreamFrame)` delivers H.264/H.265 data plus a timestamp. **One frame
    may arrive as several slices with the same timestamp, which must be concatenated before decoding.** There are
    calls for `requestStreamIframe()` and `setStreamEncode(isH265)`, and `PreviewStreamParamsUpdate` reports the
    width, height and fps.
* **Desktop SDK:** an Insta360 contributor answered an "Insta360 Ace Pro 2" issue with *"Currently, the SDK only
  supports panoramic cameras"* and referred collaboration requests to Enterprise@insta360.com.
* **SDK access:** the SDK repositories are public on GitHub. Asking Insta360 Enterprise about an ACE iOS SDK timeline is
  worthwhile, because an official SDK would remove the main long-term risk (section 8).

## 3. Protocol discovery

No official documentation of the Wi-Fi protocol exists. The description below is the intersection of independent
reverse-engineering projects, cross-checked byte for byte:

| Source | Camera(s) | What it contributes |
| --- | --- | --- |
| RigacciOrg/insta360-wifi-api (2023, GPL-3.0) | ONE RS | Original port-6666 client; protobuf descriptors extracted from the Android app (`pb2/*.py`) |
| xaionaro-go/insta360ctl `doc/protocol.md` | X3/X4/X5, ONE RS, Ace Pro (BLE) | Most complete written spec: framing, sync, keepalive, stream header |
| Daiki-Iijima/insta360-go-ultra-sdk (2026) | GO Ultra | Packet capture; H.265 Annex B at offset 12; 1080p30 preview |
| PyPI `insta360` 0.1.22 (avilabss) | several | Stream header from libOne.so: type byte at 3, u64 timestamp at 4–11 |
| dhaneshshanmugam36-alt/ace-studio (2026) | **Ace Pro 2** | Linux app with Wi-Fi live view, recording and file copy for the Ace Pro 2, built on the PyPI client |
| ibrahimhnif/opencyclo | **Ace Pro 2** | Same framing "verified live against an Ace Pro 2" (over BLE); notes per-device Wi-Fi passwords on newer models |

Field numbers and enum values used by this project were decoded from the published protobuf descriptors (parsed as
data, not executed): `StartLiveStream`, `VideoResolution`, `LiveStreamParamsUpdate`, `MessageCode`, `GetOptions`/
`Options`, `StartCapture`, `StopCapture`, `Error`.

### 3.1 Wire format

All integers are little-endian.

```
packet     = u32 total_length (includes these 4 bytes) + payload
SYNC       = 06 00 00 "syNceNdinS"                         client sends after connect; camera echoes
KEEPALIVE  = 05 00 00                                      every ~2 s; camera drops the link after ~10 s of silence
MESSAGE    = 04 00 00  code:u16  02  seq:u24  80 00 00  protobuf body
             code: request = command id; response = 200/400/500/501 with the request's seq; >= 8192 = notification
STREAM     = 01 00 00  type:u8  timestamp:u64  data
             type 0x20 = video (raw H.264/H.265 Annex B NAL units), 0x30 = gyro, 0x40 = sync
```

| Id | Command / notification | Used for |
| --- | --- | --- |
| 1 / 2 | START_LIVE_STREAM / STOP_LIVE_STREAM | preview on/off |
| 4 / 5 | START_CAPTURE / STOP_CAPTURE | camera-native recording (stop response carries the file URI) |
| 8 | GET_OPTIONS (48 camera_type, 30 firmware, 15 serial) | provenance in session metadata |
| 105 | IFRAME_REQUEST | key frame after loss/decoder errors |
| 8234 | UPDATE_LIVE_STREAM_PARAMS notification | codec (0 H.264, 1 H.265), width, height, fps |

`StartLiveStream` as sent by ace-studio to an Ace Pro 2 (and by default here): `enableVideo=true`,
`audioSampleRate=48000`, `resolution` tried in the order 1920×1080p30 (29) → 1280×720p30 (43) → 1440×720p30 (9),
`resolution1=424×240p15 (34)`. The ordered fallback in ace-studio suggests the accepted value may depend on mode or
firmware, so this implementation tries the list and records which value the camera accepted.

### 3.2 Discrepancies between sources (and how they are handled)

| Point | Disagreement | Handling |
| --- | --- | --- |
| Stream timestamp unit | µs (insta360ctl, libOne.so-derived) vs "PTS (ms)" (GO Ultra notes) | Inferred from the median frame spacing; frames are flagged `provisional` until the unit locks (≈6 frames); the raw values are always recorded |
| Handshake | SYNC echo expected (most sources) vs "wait for the first heartbeat" (BLE) | Any well-formed packet completes the handshake; unknown packets are logged in hex |
| START_LIVE_STREAM acknowledgement | always 200 in the sources | If it times out but video is flowing, streaming continues (logged as a warning) |
| Frame slicing | Android SDK: several slices per frame, same timestamp | Pictures are reassembled by timestamp before decoding (safe mode), or by an idle gap with automatic fallback (low-latency mode) |

## 4. Verified connection steps

1. Turn on the camera and enable its Wi-Fi (swipe down on the screen). The network name and password are shown under
   *Settings > Wi-Fi Settings*. Newer models use per-device passwords; `88888888` is only the older default.
2. Join the network: iPad *Settings > Wi-Fi*, or the in-app **Join camera Wi-Fi** button (system consent prompt).
3. TCP connect to `192.168.42.1:6666`, forced onto the Wi-Fi interface (`requiredInterfaceType = .wifi`) so that a
   cellular iPad does not route around a network without internet.
4. Send SYNC and KEEPALIVE; wait for the camera's first packet (handshake timeout 5 s).
5. GET_OPTIONS for model, firmware and serial (optional; failure is non-fatal).
6. START_LIVE_STREAM (resolution fallback list), then IFRAME_REQUEST.
7. Receive STREAM packets: reassemble pictures → Annex B → VideoToolbox → frames with camera timestamps.
8. Send a keepalive every 2 s. Watchdogs: no bytes for 10 s → reconnect; no video for 2 s → key frame request; for 8 s →
   reconnect (exponential backoff 1 → 10 s).

Verification status: steps 3–8 pass against a protocol-accurate mock camera (H.264 and H.265, split pictures,
rejected resolutions, silent peer, refused port, dropped link) in the test suite. On real hardware they are documented
by the projects above, but not yet observed by this project.

## 5. Supported features

| Feature | Protocol element | Evidence for Ace Pro 2 | In this implementation |
| --- | --- | --- | --- |
| Live preview over Wi-Fi | cmd 1/2, stream 0x20 | ace-studio (Wi-Fi live view on Ace Pro 2) | Yes |
| H.264 and H.265 | 8234 / SPS detection | Android SDK documents both | Yes, auto-detected, hardware decode |
| Stream parameters | notification 8234 | protobuf descriptor | Yes, logged and recorded |
| Key frame on demand | cmd 105 | Android SDK `requestStreamIframe` | Yes, throttled |
| Camera-native recording | cmd 4/5 | ace-studio records on Ace Pro 2 | Yes, optional ("experimental"): host times of request/ack and the returned file URI go into session.json |
| Recording while previewing | — | not documented | **Unverified**; check with ace-probe + manual test |
| Model / firmware / serial | cmd 8 | Options field numbers | Yes |
| Gyro stream | stream 0x30 | sources disagree on layout | Not used (counted only) |
| Join the camera AP from the app | NEHotspotConfiguration | Apple API | Yes (iPad, with entitlement); manual fallback |

## 6. Video format, resolution, frame rate, latency

| Property | Known | Will be measured by |
| --- | --- | --- |
| Codec | H.264 or H.265 (both documented for the SDK preview) | `ace-probe` ("codec"); app status row |
| Resolution | requested 1920×1080p30 first; the camera may accept a lower one | `ace-probe` (decoded size, accepted request) |
| Frame rate | nominal 30 fps requested | `ace-probe` (median spacing of camera timestamps) |
| Timestamp unit | µs or ms | `ace-probe` ("timestamp unit") |
| Bitrate | unknown | `ace-probe` (Mbit/s) |
| Missing frames | unknown | gaps in camera timestamps (app + probe) |
| Network jitter | unknown | residual of arrival − camera time after a linear fit (probe) |
| Assembly wait | ≈ one frame interval in safe mode, a few ms in low-latency mode (mock: 37 ms vs 5 ms) | app metrics bar, frames.csv |
| Decode time | mock 160×120 HEVC: ~2 ms on an M3 | app, probe |
| Glass-to-result latency | unknown; includes camera exposure, ISP/encoder, Wi-Fi, assembly, decode, analysis | in-app screen-flash test (camera pointed at the iPad), ±1 display refresh |

The analysis itself (release build, Apple M3, synthetic particle images) takes 3.2 ms per 640×480 frame (~565
particles), 7.8 ms per 1280×720 frame (~1450 particles) and 18.5 ms per 1920×1080 frame (~2900 particles). That is
real time at 30 fps on the Mac; iPad figures will differ and are shown live in the app ("Analyse" metric).

## 7. Connection stability

* Range is about 50 m in open space (Insta360 manual); the lab will be much closer.
* Keepalives and both watchdogs are implemented; reconnects are automatic, counted and logged with timestamps.
* iPadOS risks: (a) auto-joining back to a known network with internet. Mitigation: join through the app (saved
  configuration), or disable Auto-Join on the lab network during experiments. (b) Backgrounding suspends networking
  and invalidates the hardware decoder session; the decoder recreates its session and the source reconnects, but the
  gap is a recorded discontinuity. Keep the app in the foreground; the idle timer is disabled while it runs.
* **Exclusive control is unknown:** the official Insta360 app connected from another phone may hold the camera. Close
  it before connecting (the diagnostics hint says so).

## 8. Known limitations and risks

1. **Unofficial protocol.** A firmware update can change it. Mitigation: pin the camera firmware for a measurement
   campaign, record the firmware string in every session (done automatically), and re-run `ace-probe` after updates.
2. **Preview ≠ recording.** The preview is a lower-bitrate stream, possibly scaled, cropped or stabilised (the 8234
   notification carries `window_crop_info` and a FlowState flag). For quantitative work:
   * disable FlowState/horizon lock and choose a fixed-FOV mode (e.g. Linear) before calibrating; otherwise the
     pixel → mm mapping can change from frame to frame;
   * calibrate mm/px in the same mode and resolution as the preview;
   * keep the camera's own recording (optional automatic start/stop) as the high-quality source, aligned to the
     analysis using the screen-flash events, which are visible in both.
3. **Timestamp semantics.** Camera timestamps are presumably capture-based, but this is not documented. Velocities
   use them, not Wi-Fi arrival times; host arrival timing is opt-in and flagged per frame.
4. **Wi-Fi join needs a paid developer account** (Hotspot Configuration and Access Wi-Fi Information capabilities).
   With a free account, remove the entitlements and join in Settings.
5. **Local Network privacy prompt** on first connection; if denied, connections stall. The app detects this
   (`unsatisfiedReason == .localNetworkDenied`) and says where to re-enable it.
6. **Security:** the camera AP is reachable by anyone who knows its password (older models defaulted to 88888888).
   Do not run experiments with sensitive data on the camera's card.
7. **Terms of use:** this is interoperability work with a camera the lab owns. Contacting Insta360 about the ACE iOS SDK
   remains the clean long-term path.

## 9. Hardware verification plan (do this first)

1. On a Mac, join the camera Wi-Fi, then from the repository:
   `swift run -c release ace-probe probe --seconds 20`
   (`--low-latency` for a second run; `--res 43` to request 720p first.)
2. Read the verdict:
   * `VERIFIED`: preview received and decoded with camera timestamps. `summary.json` contains codec, resolution, fps,
     timestamp unit, missing frames, jitter, bitrate and late slices.
   * `PARTIAL` / `NOT VERIFIED`: the failing stage is named, and `packets.jsonl` holds the first 3000 packet headers
     for analysis.
3. On the iPad: build the app, connect, run the screen-flash latency test and a 10-minute stability run while
   recording. Check *Missing frames*, *Reconnects* and *Decode errors* in session.json.
4. Optionally test camera-native recording during preview, and the USB webcam fallback (section 10c).

Acceptance criteria to fix before experiments: decoded resolution ≥ 1280×720, measured fps within 1 % of nominal,
missing frames < 0.5 % over 10 minutes, glass-to-result latency acceptable for the experiment (to be decided by the
team once measured).

## 10. Fallbacks (only if section 9 fails)

| Option | Keeps Ace Pro 2 | Notes |
| --- | --- | --- |
| a. Android phone with the official SDK relaying to the iPad | Yes | Officially supported preview (raw stream API documented). Needs an Android app and a local relay (adds latency and a device); acceptable only if a relay is allowed. |
| b. Same Ace Pro 2 as USB webcam on a USB-C iPad (iPadOS 17 external cameras) | Yes | Implemented as `ExternalCameraSource`. Insta360 documents Webcam mode for computers only; acceptance by iPadOS is unverified. Cheap to test: plug in, select "USB camera". |
| c. RTSP IP camera | No | Mature, documented; needs an RTSP client implementation for iPad (not included). |
| d. Another action camera with an officially documented live-preview API | No | E.g. GoPro's Open GoPro API publishes a preview stream; not evaluated here. |

The `CameraVideoSource` abstraction keeps any of these to a single new source class; nothing downstream changes.

## 11. Sources

* Insta360 developer docs (ACE overview, iOS guide, Android camera integration / API): https://github.com/Insta360Develop/Insta360-Developer_Docs
* Insta360 iOS SDK README: https://github.com/Insta360Develop/iOS-SDK
* Desktop SDK issue "Insta360 Ace Pro 2": https://github.com/Insta360Develop/Desktop-CameraSDK-Cpp/issues/73
* Insta360 developer page (device lists; automated fetch refused, search snippet only): https://www.insta360.com/sdk/home
* RigacciOrg/insta360-wifi-api: https://github.com/RigacciOrg/insta360-wifi-api
* xaionaro-go/insta360ctl protocol: https://github.com/xaionaro-go/insta360ctl/blob/main/doc/protocol.md
* Daiki-Iijima/insta360-go-ultra-sdk protocol: https://github.com/Daiki-Iijima/insta360-go-ultra-sdk/blob/main/docs/protocol.md
* PyPI insta360: https://pypi.org/project/insta360/
* ace-studio (Ace Pro 2): https://github.com/dhaneshshanmugam36-alt/ace-studio
* OpenCyclo Ace Pro 2 notes: https://github.com/ibrahimhnif/opencyclo/blob/main/docs/insta360-camera-control.md
* Ace Pro 2 manual, Wi-Fi password: https://onlinemanual.insta360.com/acepro2/en-us/faq/operationtutorials/password
* Ace Pro 2 manual, Webcam mode: https://onlinemanual.insta360.com/acepro2/en-us/camera/appuse/webcammode
* Apple TN3111 iOS Wi-Fi API overview: https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview
* Apple TN3179 Local network privacy: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
* Apple NetworkExtension headers (NEHotspotConfigurationManager.h, NEHotspotNetwork.h) in the SDK
* WWDC23 "Support external cameras in your iPadOS app": https://developer.apple.com/videos/play/wwdc2023/10106/
