# Wallpaper Porter

A small native macOS app that turns **Wallpaper Engine** Workshop wallpapers into wallpapers you can use on your Mac. Paste a Steam Workshop link and it downloads, converts and sets it.

![icon](Resources/AppIcon.png)

## What it does

| Wallpaper Engine type | What you get on macOS |
|---|---|
| **Video** | Plays **live** behind your desktop icons (muted, looping, on every display), or as a still frame |
| **Scene** | Unpacks `scene.pkg`, converts the `.tex` textures (DXT1/3/5, RGBA, LZ4, embedded PNG/JPG/MP4) to PNG and picks the main background. Use **Choose Image…** to pick another layer. Animations and effects don't carry over. |
| **Web** | Runs **live** in a desktop-level web view, with Wallpaper Engine's default settings passed in |
| **Application** | Windows-only, so only the preview image is saved |

Other features:
- Paste several links at once; they're downloaded one after another
- **Import Folder…** for Workshop folders you already have (anything with a `project.json`)
- Library of everything you've converted, saved in `~/Pictures/Wallpaper Engine for Mac/`
- Menu bar icon to pause or stop the live wallpaper, plus **Open at Login**
- The live wallpaper comes back automatically after a restart and pauses while the display sleeps

## Requirements

- macOS 13 Ventura or later (Apple Silicon or Intel)
- A Steam account that **owns Wallpaper Engine**. Workshop downloads are tied to ownership; the app uses your own account and never sees your password.
- Xcode or the Command Line Tools to build it (`xcode-select --install`)
- On Apple Silicon, Rosetta (SteamCMD is an Intel program). The sign-in step offers to install it.

## Build

```bash
git clone <this repo>
cd WallpaperPorter
./build.sh
mv "build/Wallpaper Porter.app" /Applications/
```

The build is a universal binary with an ad-hoc signature. If someone else built it and sent you the `.app`, macOS may block it the first time: right-click it, choose **Open**, then **Open** again. Or run `xattr -dr com.apple.quarantine "/Applications/Wallpaper Porter.app"`.

## First run

1. **Install SteamCMD.** One click; it downloads Valve's official tool into `~/Library/Application Support/Wallpaper Porter/`.
2. **Enter your Steam account name.** This is the login name, not your display name.
3. **Sign in to Steam…** opens Terminal. Type your password and Steam Guard code there. SteamCMD remembers the login, so later downloads don't ask again.
4. Paste a link such as `https://steamcommunity.com/sharedfiles/filedetails/?id=1234567890` and press **Import**.

## Troubleshooting

- **"Steam needs you to sign in again"**: the saved login expired. Click the gear icon, then **Sign in to Steam…**.
- **Download failed**: make sure the account owns Wallpaper Engine and the item isn't private or removed. The line under the failed import shows SteamCMD's last message.
- **Bad CPU type / SteamCMD won't start (Apple Silicon)**: run `softwareupdate --install-rosetta --agree-to-license`.
- **The wallpaper only changed on one Space**: macOS sets still wallpapers per Space. Live wallpapers show on all Spaces.
- **A video won't play live**: some wallpapers use `.webm`, which macOS can't play. Convert it to MP4 (for example with HandBrake) and use **Import Folder…**.

## How it works

```
Sources/
  Views.swift          SwiftUI window, menu bar extra, app entry point
  AppModel.swift       Import queue, library, Steam setup state
  Steam.swift          Link parsing, Steam Web API lookup, SteamCMD wrapper
  Converter.swift      project.json → video / scene / web handling, desktop setting
  PKG.swift            scene.pkg unpacker (with path-traversal protection)
  TEX.swift            .tex decoder + LZ4 block + DXT1/3/5 decoders
  LiveWallpaper.swift  Desktop-level windows with AVPlayer / WKWebView
  BinaryReader.swift   Little-endian reader
```

The PKG/TEX format handling is based on the community's reverse-engineering work, notably [RePKG](https://github.com/notscuffed/repkg).

## Please note

Workshop wallpapers belong to their creators and are shared for use with Wallpaper Engine. This tool is for personal use with wallpapers from an account that owns Wallpaper Engine. Don't redistribute other people's wallpapers.

Not affiliated with Wallpaper Engine, Kristjan Skutta or Valve.

## License

MIT, see [LICENSE](LICENSE).
