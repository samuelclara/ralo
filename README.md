# Watchpost

A calm, secure iPhone and iPad client for Arlo cameras, built in the Amber Glass design
(the Stash V2 system) with iOS 26/27 Liquid Glass.

Watchpost is **not made by or affiliated with Arlo**. Arlo has no public API; Watchpost talks to
Arlo's cloud the same way Arlo's own website does, following the open-source
[pyaarlo](https://github.com/twrecked/pyaarlo) and [Scrypted Arlo](https://github.com/scryptedapp/arlo)
projects. Arlo can change this at any time, and using it may go against Arlo's terms.

## Build and install

You need a Mac with **Xcode 26 or later** and an iPhone or iPad on **iOS 26 or later**.

1. Open `Watchpost.xcodeproj`.
2. Copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and put your
   **Team ID** in it (a free Apple ID works; it signs the app for 7 days at a time). That file is
   git-ignored, so your team never ends up in the repository. Don't pick the team in Xcode's
   Signing & Capabilities tab: Xcode would write it into the committed project file.
3. If Xcode says the bundle identifier is taken, set `PRODUCT_BUNDLE_IDENTIFIER` in the same file
   to something unique, e.g. `com.yourname.ralo`.
4. Plug in your device, pick it as the run destination, and press **Run**.
   On the device, trust the developer in **Settings → General → VPN & Device Management**.

There are no packages to fetch: the app uses only Apple frameworks.

## What's in it

| Screen | What it does |
|---|---|
| Home | Security mode (Away / At home / Off), camera grid with latest frames and motion badges, today's visits |
| Live view | HLS live video, glass control bar: Talk, Siren (with confirmation), Light, Snapshot to Photos, cloud Record |
| Clips | Day picker, visits grouped by camera and time, filters for people / vehicles / parcels / animals, playback |
| Alerts | Which event types Watchpost flags; push notifications stay with Arlo's app |
| Settings | Lock timing, lock now, sign out and forget the device, what's stored |

On iPad the tab bar becomes a sidebar and the layouts widen.

## Security

- **Password stored only if you ask.** By default it's sent once to Arlo's sign-in server over TLS
  and dropped from memory. With **Stay signed in** (on by default at sign-in, can be switched off in
  Settings) it's kept in the same Keychain item as the token, so Ralo can sign in again by itself
  when Arlo's token expires. Arlo has no refresh token, so this is the only way to renew it.
- **Trusted device, so no code every time.** After the first verification code, Ralo pairs the
  device with Arlo (as Arlo's website does with "trust this browser") and keeps Arlo's trust cookies
  in a this-device-only Keychain item. Later sign-ins skip the code. Signing out forgets the device.
- **Sign-in in the Keychain, behind Face ID.** The Arlo token (and password, if kept) is saved with
  `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` + `.userPresence`: readable only after Face ID,
  Touch ID or the passcode, never synced to iCloud, never restored to another device, and deleted by
  iOS if the passcode is removed. A device passcode is required.
- **One prompt.** Unlocking the app and opening the Keychain item share one authenticated context.
- **Locks when you leave.** Immediately by default (1 or 5 minutes optional). Locking drops the
  token, the password, the event connection and every cached image from memory. The app-switcher snapshot is
  covered.
- **Token stays on Arlo's hosts.** Only `myapi.arlo.com` and `ocapi-app.arlo.com` (and Arlo's MQTT
  broker, checked against Arlo's domains) ever receive it. Redirects are refused. Snapshots, clips
  and live video use Arlo's pre-signed links without credentials.
- **No disk traces.** Ephemeral `URLSession`s with no URL cache; images are held in memory only;
  clips stream and are never downloaded.
- **No proxies, modern TLS.** System and profile proxies are ignored; TLS 1.2+ only; App Transport
  Security has no exceptions.
- **Talk is sandboxed.** Two-way audio runs in a hidden, non-persistent web view loaded from a
  bundled page that can't navigate anywhere. Only that page gets the microphone, only while talking.
- **No analytics, no third-party code, no server.**

Not done on purpose: certificate pinning (Arlo sits behind Cloudflare, whose certificates rotate;
pinning would break the app without warning), and jailbreak detection (easily bypassed).

## Known limits

- **Sign-in may be blocked.** Arlo's sign-in sits behind Cloudflare bot protection. Watchpost
  presents itself as Safari on iPad, which usually passes, but this can't be verified until it runs
  on a device.
- **Two-way talk** works on cameras using Arlo's WebRTC push-to-talk. Cameras that use Arlo's newer
  SIP talk show a message instead.
- **Modes.** Location-based accounts get Away / At home / Off. Older base-station accounts only have
  Armed and Disarmed, so At home is disabled. With several locations, the first one is used.
- **Push notifications** come from Arlo's app; Watchpost has no server.
- **Siren and Light** are enabled from a list of models known to have them.

## Project layout

```
Watchpost/
  App/            entry point, app state (lock, sign-in, scene handling), tabs
  Arlo/           API client, sign-in with 2FA, models, event stream (MQTT / SSE)
  Security/       Keychain, session vault, Face ID lock
  Store/          camera store, visit grouping, preferences, private image loader
  Talk/           WebRTC two-way talk (Swift bridge + bundled page)
  DesignSystem/   Amber Glass tokens, Urbanist font, components
  Features/       Home, Live, Clips, Alerts, Settings, Sign-in, Lock
  Resources/      Urbanist (SIL Open Font License)
```
