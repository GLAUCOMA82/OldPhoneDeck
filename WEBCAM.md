# Phone as a webcam and microphone

Your iPhone's camera and mic can feed video calls on the Mac: the camera through OBS's virtual camera, the mic through BlackHole.

- **Modern iPhone or iPad:** nothing to install. Open the secure deck (`https://…:8047`, see the README) and use the **Camera → Mac** and **Mic → Mac** keys, or the **Camera & Mic** widget. Safari streams over a secure WebSocket.
- **iPhone 4S (iOS 8/9):** Safari 9 can't use the camera, so the phone runs **PhoneCam**, a small native app in [PhoneCam/](PhoneCam/). It shows the deck and streams the camera and mic at the same time, over Wi-Fi or the USB cable.

```
iPhone 4S                                     Mac (PhoneDeck)
┌───────────────────────────┐  Wi-Fi :8046   ┌──────────────────────────────────────────────┐
│ PhoneCam                  │  or USB cable  │ /camera.mjpg ─▶ OBS Media Source ─▶ "OBS      │
│  camera 640×480 JPEG 15fps│ ─────────────▶ │                     Virtual Camera" in any app│
│  mic 16 kHz mono          │  video + PCM   │ mic PCM ─▶ BlackHole 2ch ─▶ pick it as the mic│
│  web view: the deck       │ ◀───────────── │ :8045 the deck                                │
└───────────────────────────┘                └──────────────────────────────────────────────┘
```

## 1. iPhone 4S: build and install PhoneCam (no jailbreak needed)

Start PhoneDeck first, then:

```bash
PhoneCam/build.sh
```

This produces `PhoneCam/build/PhoneCam.ipa`, built for armv7 / iOS 8 and later, with this Mac's address and access code
baked in (the **SET** button changes the address later). The first run downloads the iOS 9.3 SDK from
`github.com/theos/sdks` and patches it so today's linker accepts it.

Install it with **Sideloadly** (sideloadly.io):
1. Plug the 4S in over USB, drag `PhoneCam.ipa` into Sideloadly, sign in with a spare free Apple ID, press Start.
2. On the phone, go to Settings → General → Profiles (or Device Management) → your Apple ID → **Trust**.
3. Open **PhoneDeck** from the home screen and allow Camera and Microphone.

The CAM and MIC buttons (top right) turn **blue** when they're streaming to the Mac and **orange** when they're
on but the Mac isn't reachable. FLIP switches between the front and back camera.

**USB cable:** with the phone plugged into the Mac and no Wi-Fi, PhoneCam reaches the Mac through the cable on its own.
The SET button shows USB while the cable is in use. Start PhoneDeck with `PHONEDECK_USB_DEBUG=1` to log connection attempts.

**The 7-day limit:** a free Apple ID's signature expires after 7 days. When the app stops opening, sign it again in
Sideloadly; that takes about 30 seconds.

## 2. Mac: webcam via OBS (one-time)

1. Install **OBS Studio** (obsproject.com).
2. Sources → + → **Media Source** → untick *Local File* → Input:
   `http://localhost:8045/camera.mjpg?k=<code>` (`<code>` is in `~/.phonedeck/token`).
   Tick *Restart playback when source becomes active*.
3. Click **Start Virtual Camera**. In Zoom, Meet, FaceTime and so on, choose **OBS Virtual Camera**.

## 3. Mac: microphone via BlackHole (one-time)

1. Install **BlackHole 2ch** (existential.audio/blackhole), a free virtual audio device.
2. Restart PhoneDeck. It finds BlackHole automatically and plays the phone's mic into it.
   Run with `--mic-device NAME` to pick a different output device.
3. In your apps, choose **BlackHole 2ch** as the microphone.

If the mic is silent:
- On the 4S, hold the **MIC** button to switch between the phone's microphones. PhoneCam uses the top one by default.
- `http://localhost:8045/info?k=<code>` has a `mic` entry: the device it plays into, whether audio is arriving,
  and how loud it is coming in and going out.
- `http://localhost:8045/mic.wav?k=<code>` is the last 10 seconds of the phone's mic exactly as the Mac received it.

Why OBS and BlackHole: a macOS virtual camera or mic has to be a signed system extension. Both are already signed
and notarized, so no Apple Developer account is needed. For plain FaceTime or Zoom calls with a modern iPhone,
macOS's built-in Continuity Camera is simpler.
