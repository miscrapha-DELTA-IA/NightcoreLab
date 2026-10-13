# Stage 14A — Share Export Profiles & Packaging

## Immutable boundaries
`StoryVideoRequest` still freezes the program/composition/material/typography.
`StoryRenderTimeline` still provides source-based integer frame time.
`StoryFrameRenderer` still renders the same `StorySceneView`.
`StoryVideoExporter` and `StoryPixelWriter` are the ONLY video encoding/mux pathway.

New product-only pieces: `ExportProfile` (option mapping), `ExportCropPolicy`
(framing), `StoryExportCanvas` (common adapter), `SharePackageBuilder`
(the existing exporter plus still capture, sidecar metadata and file references).

```text
User -> ExportProfile -> frozen StoryVideoRequest + StoryEncodingProfile
     -> StoryVideoExporter -> SharePackageBuilder -> SharePackage
```

## Export matrix

| Quality | FPS | bitrate | portrait | square | landscape |
|---|---:|---:|---|---|---|
| Economy | 15 | 1.6 Mbps | 540x960 | 540x540 | 960x540 |
| Balanced | 20 | 2.8 Mbps | 720x1280 | 720x720 | 1280x720 |
| High | 30 | 5.5 Mbps | 1080x1920 | 1080x1080 | 1920x1080 |

All profiles currently produce H.264 video in MP4; HEVC is deliberately
excluded until device/Photos compatibility is tested.

**Default compatibility:** the draft continues freezing
`StoryEncodingProfile.recommended()`, which chooses the existing 720x1280/20
or low-power 540x960/15. `ExportProfile.matching(draft.profile)` restores
that captured quality in the UI. Neither the original 9:16 content hierarchy
nor its frame grid changes. A 9:16 output bypasses the new framing ZStack.

## Cropping and safe content

The source scene is **always** authored at 540x960 points.

* `safeAreaPreserving` (default): fit the complete scene on the destination
  and fill any remaining bars with a subtle theme-colored background.
  Lyrics, artwork, captions, header/footer and the source material remain
  visible. This is not a native 1:1/16:9 reflow.
* `aspectFit`: fit complete scene on a black canvas.
* `centerCrop`: fill the available destination and intentionally crop
  vertical content. Only available in Player mode. In Lyrics mode it
  deterministically falls back to `safeAreaPreserving` to avoid deleting
  active lyric and typography regions.

The same `StoryExportCanvas` view is used by the scrub preview and
`StoryFrameRenderer`; the export and thumbnail also use the same frozen
`StoryRenderTimeline`. Ratio/quality changes may alter FPS/frame-grid by
explicit selection only. No new shader or reactive path is introduced.

## SharePackage (not ZIP)

```text
NightcoreShare-<uuid>/
    video.mp4
    thumbnail.jpg
    metadata.json
```

Metadata is a versioned, public-only JSON sidecar. It contains title, artist,
preset and material identities, duration, dimensions, FPS, codec, quality,
aspect ratio, framing policy and exact thumbnail frame index/elapsed time.
No local source URLs, JWT, authentication tokens, internal paths or personal
identifiers are serialized. The MP4 currently retains its existing public
metadata behavior; the sidecar is the authoritative extended metadata source.

The thumbnail is the *first video frame* and shares the exact frame resolution
and aspect framing, encoded as JPEG after `StoryFrameRenderer.render`.
The generated MP4 is verified with AVFoundation for actual video dimensions,
positive duration and required audio track before it becomes shareable.

`ShareLink` offers the video, image, JSON and multi-item share sheet. The
system share sheet's "Save to Files" action handles local file saving; the
original Photos-saving workflow stays intact.

Aborted or failed package builds remove their temporary folder and video.
A successful package remains in the system temporary directory so iOS
ShareLink/Photos can read it after view dismissal; do not delete on dismissal.
No ZIP/archive layer has been added.

## Test coverage

`ShareExportPipelineTests`: default compatibility, dimension/FPS table,
safe-lyrics crop policy, Codable metadata/profile, all three aspect pixel
sizes, preview/source runtime contract and creation/validation of a real
MP4 + thumbnail + sidecar package.

**Still required before merge:** iOS CI `xcodegen`, XCTest, Release build,
unsigned IPA; manual inspection of lyric frames on 1:1 / 16:9; device memory
and Metal GPU measurements, especially High 1080p/30fps. No unmeasured
performance gain is claimed.
