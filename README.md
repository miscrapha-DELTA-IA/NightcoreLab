<p align="center">
  <img src="./branding/gnarly-banner (1).jpg" alt="Gnarly: neon green grid sphere with slime lettering" width="100%">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-17%2B-000000?style=for-the-badge&logo=apple&logoColor=white" alt="iOS 17+">
  <img src="https://img.shields.io/badge/SwiftUI-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="SwiftUI">
  <img src="https://img.shields.io/badge/Metal-39FF14?style=for-the-badge&logo=apple&logoColor=black" alt="Metal">
  <img src="https://img.shields.io/badge/Backend-FastAPI-009688?style=for-the-badge&logo=fastapi&logoColor=white" alt="FastAPI">
</p>

<h3 align="center">
  A Nightcore, Slowed + Reverb and karaoke player with real-time typography.
</h3>

---

## What it is

**Gnarly** (formerly NightcoreLab) is an iOS app built with SwiftUI. It plays and transforms songs with Nightcore and Slowed + Reverb, shows lyrics word by word in karaoke mode, scores your singing through the microphone, and exports videos that match the preview frame for frame.

## Repository layout

| Folder | Contents |
| --- | --- |
| `NightcoreLab/` | App source (SwiftUI, AVAudioEngine, Metal shaders) |
| `NightcoreLabTests/` | Unit tests |
| `backend/` | Service that fetches and processes audio, deployed on Render |
| `docs/` | Technical documentation, stage by stage |
| `branding/` | Logo and banner |
| `scripts/`, `fastlane/` | Build automation |

## Running the app

The `.xcodeproj` is not versioned. `project.yml` is the source of truth, and the project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
open NightcoreLab.xcodeproj
```

Requirements: iOS 17.0 or later (iPhone) and Xcode 16 or later.

## License

No public license has been defined for this repository yet.
