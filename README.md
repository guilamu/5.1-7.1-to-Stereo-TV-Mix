# Surround-to-Stereo TV Mix

Adds a stereo track to your movies where **dialogue is clear and explosions are brought down to the
level of the voices** — the "night mode" your TV or soundbar promises but rarely delivers.

Feed it an MKV with a 5.1 or 7.1 soundtrack. It writes a levelled stereo track back into the same
file, next to the original track. **The video is never re-encoded**: only audio is processed, so a
20 GB movie takes about as long as copying it once.

```powershell
.\Convert-SurroundToStereo.ps1 "D:\Movies\TeneT.mkv"
```

Windows, PowerShell 5.1 (shipped with Windows), and `ffmpeg` — nothing else.

---

## Why

Cinema mixes are made for a cinema: a huge dynamic range, no neighbours, no fridge humming in the
next room. At home, in the evening, you end up riding the volume control — up for the whispered
line, down for the explosion that follows it.

The stereo downmix your player falls back on does not help. It simply adds the channels together
with fixed coefficients, so the gap between voices and everything else survives untouched.

## How it works

The whole approach rests on one property of a 5.1/7.1 mix: **dialogue lives in the centre channel**,
and almost nothing else does. No source separation and no machine learning are needed — the centre
channel can simply be pulled out and treated on its own.

The filter graph therefore splits the source into two paths:

* **Dialogue path** — the centre channel alone, run through `dynaudnorm` in RMS mode, levelling in
  *both* directions: whispers come up, shouted lines come down, everything converges on a steady
  level.
* **Music/FX path** — front, surround and LFE channels mixed to stereo, compressed, then capped
  *downwards only* (`dynaudnorm` with maximum gain = 1). Loud passages are pulled down to the level
  of the voices, but quiet ambiences are never amplified — which is what avoids the pumping and the
  raised hiss you hear from consumer night-mode presets.

Both paths can be loud at the same time (an argument during a gunfight), and they add up at the
remix. A `sidechaincompress` keyed off the processed dialogue path therefore ducks the music and
effects whenever speech is present — the same trick a radio station uses to put a presenter's voice
over a track.

Everything then runs in three ffmpeg passes:

| Pass | What it does | Speed |
|---|---|---|
| 1 | EBU R128 loudness of a plain downmix, giving a pre-gain that brings any film to -23 LUFS | audio only, fast |
| 2 | EBU R128 loudness after the dynamic processing, giving the final gain to hit the target | audio only, fast |
| 3 | Encodes the stereo track and remuxes the file (video copied verbatim) | disk-bound |

The pre-gain from pass 1 is what makes the settings portable: compressor thresholds react the same
way on a quietly mixed film and on a loud one, so nothing has to be tuned per movie.

Pass 3 keeps subtitles, chapters and attachments, places the stereo track first, titles it
`TV Stereo (Night Mode)`, and leaves the original surround track in the file.

## Results

Measured as the gap between loud effects (90th percentile) and the median dialogue level — the
number that decides how often you reach for the remote:

| Film | Before | After |
|---|---|---|
| Dune (2021) | +5.8 dB | -1.1 dB |
| Tenet (2020) | +12.0 dB | +1.9 dB |

Tenet is the interesting case: a mix notorious for buried dialogue, starting 6 dB worse than Dune,
and landing in the same window afterwards. Quiet dialogue also gains 2 to 2.5 dB relative to average
dialogue, while ambiences stay 11 to 14 dB below the voices — so room tone does not creep up during
silences.

## Requirements

* Windows with PowerShell 5.1 or later (PowerShell 7 works too)
* `ffmpeg.exe` and `ffprobe.exe` in `PATH`, or pointed at with `-FFmpegPath`

## Install

Download `Convert-SurroundToStereo.ps1` and `Convertir-en-stereo.cmd` and keep them **in the same
folder** — the launcher looks for the script next to itself.

If PowerShell refuses to run the script (`running scripts is disabled on this system`), either use
the `.cmd` launcher, which sets its own execution policy, or unblock the file once:

```powershell
Unblock-File .\Convert-SurroundToStereo.ps1
```

## Usage

```powershell
# One file, default settings
.\Convert-SurroundToStereo.ps1 "D:\Movies\Dune.mkv"

# A whole series, recursively, preferring the French track as the source
.\Convert-SurroundToStereo.ps1 "D:\Series\Dark" -Language fre

# Make the stereo track the one players start on
.\Convert-SurroundToStereo.ps1 "D:\Movies\Dune.mkv" -StereoDefault

# Keep the source file and write a second one next to it
.\Convert-SurroundToStereo.ps1 "D:\Movies\Dune.mkv" -Suffix ".stereo"

# Audition a 2-minute excerpt before committing to a 20 GB film
.\Convert-SurroundToStereo.ps1 "D:\Movies\Dune.mkv" -PreviewFrom 00:45:00 -PreviewLength 120
```

Mouse users: **drag files or folders onto `Convertir-en-stereo.cmd`**, or double-click it and answer
the prompt. Windows cannot do either with a `.ps1` directly — double-clicking one opens it in
Notepad, and Explorer refuses the drop — which is the only reason the launcher exists. It also keeps
the window open at the end so you can read the report.

Run the script without arguments and it asks what to process; pressing Enter alone takes every video
file in the current folder.

## Options

| Parameter | Default | Description |
|---|---|---|
| `-Path` | prompt | Files, folders or wildcards. Folders are searched recursively (mkv, mp4, m4v, mov, ts, m2ts, avi, wmv, webm) |
| `-Mode` | `night` | `night` for heavy levelling, `balanced` to keep some contrast |
| `-Codec` | `aac` | `aac`, `ac3`, `eac3` or `flac` for the stereo track |
| `-Bitrate` | `192k` | Bitrate of the stereo track; ignored for `flac` |
| `-TargetLufs` | `-16` | Integrated loudness target |
| `-TruePeak` | `-1.5` | True-peak ceiling in dBTP |
| `-Language` | — | Preferred ISO 639-2 language (`fre`, `eng`, …) when picking the source track |
| `-AudioStream` | auto | Force the source track by index, counted among audio streams |
| `-StereoDefault` | off | Put the `default` flag on the stereo track, so players start on it |
| `-DropOriginalAudio` | off | Keep only the stereo track in the output |
| `-OutputDir` | — | Write elsewhere and leave the source untouched |
| `-Suffix` | — | e.g. `.stereo`; produces a second file instead of replacing the source |
| `-PreviewFrom` / `-PreviewLength` | — / `90` | Render an excerpt instead of the whole film; analysis still runs on the full film |
| `-Verify` | off | Re-measure the produced track after encoding and print the result |
| `-Overwrite` | off | Overwrite an existing output, and redo a file that already contains a generated track |
| `-FFmpegPath` | `PATH` | Folder holding `ffmpeg.exe` / `ffprobe.exe` |
| `-Ask` | off | Ask in the console for what was not given on the command line (used by the launcher) |

`Get-Help .\Convert-SurroundToStereo.ps1 -Full` prints the built-in help (in French).

## About replacing the source file

By default the output **takes the place of the input file**: the stereo track is added to the movie
and no second file is left behind. Adding a track to an MKV technically requires rewriting the
container, so the script writes a temporary `.part.mkv`, checks its duration, size and track count,
and only then deletes the original. Two consequences:

* You need room for both files while a conversion runs.
* If anything looks wrong with the produced file, the original is kept and the script says so.

Use `-Suffix ".stereo"` or `-OutputDir` if you would rather keep both files side by side.

Re-running the script on an already converted file is a no-op: generated tracks are recognised by
their title, and the file is skipped unless `-Overwrite` is given — in which case the old generated
track is replaced, not stacked on top.

## Which track plays by default

The stereo track is placed first but does **not** carry the `default` flag: players start on the
original surround track, and stereo is a manual choice. Pass `-StereoDefault` to invert that. With
`-DropOriginalAudio` the stereo track is the only one left and is flagged default regardless.

## Known limitations

* **The "dialogue is in the centre" assumption can fail** — some TV series put voices in L/R, as do
  old remastered mixes and 5.1 tracks upmixed from stereo. On those the centre path has little to
  work with, and dialogue gets the downward treatment meant for everything else.
* **Effects carried by the centre channel** (a gunshot, a door slam) are levelled to the same RMS as
  dialogue, by design. Their transient is only held back by the limiter.
* **7.1 sources** are handled by the same formulas, with rear channels weighted slightly lower, but
  have not been tested against a real 7.1 mix.
* **Output is always MKV.** MP4 would force subtitle conversion and exclude PGS subtitles.
* **Three decodes per film**, and pass 3 is limited by disk throughput since the video is copied.
* The true-peak headroom for lossy codecs is a fixed 2 dB. Aim for `TruePeak - 3` if you need a
  strict guarantee.
* Validation so far is **metric, on two films** (Dune and Tenet). Reports on unusual mixes —
  animation, concerts, old remasters — are welcome.

## Glossary

* **5.1 / 7.1** — A mix spread over 6 (or 8) discrete channels: front left and right, centre,
  subwoofer, and the rear surrounds (plus side surrounds in 7.1). Each is a separate stream in the
  file, which is what makes per-channel processing possible.
* **Centre channel (FC)** — The speaker under the screen. By mixing convention this is where dialogue
  goes, so it stays anchored to the picture wherever the viewer sits. The whole script rests on this.
* **LFE** — *Low Frequency Effects*, the subwoofer channel, carrying only deep bass (below ~120 Hz).
  Mixed in at 30% here, so a soundbar keeps its weight without a small speaker choking on it.
* **Downmix** — Folding several channels into fewer, here 5.1 into stereo. The naive downmix your
  player performs just sums channels with fixed coefficients, which is exactly why dialogue stays
  buried.
* **Remux** — Rewriting a container (the MKV) with a different set of tracks, without touching the
  video data. Near-instant compared to re-encoding, and lossless.
* **Dynamic range** — The gap between the quietest and the loudest passages. Cinema cultivates a lot
  of it; a living room with neighbours tolerates far less. Reducing it intelligently is the whole job.
* **Compressor** — Reduces level above a threshold by a given ratio (4:1 means an 8 dB overshoot
  comes out as 2 dB). *Attack* and *release* set how fast it reacts and recovers, in milliseconds.
* **RMS** — A way of measuring level over a short time window, closer to perceived loudness than an
  instantaneous peak reading. The processing here is RMS-detected for that reason.
* **`dynaudnorm`** — An ffmpeg dynamic normalisation filter: it splits audio into frames and corrects
  the gain of each towards a target, smoothing between frames. Unlike a compressor it can also
  *amplify* what is too quiet — hence its use on dialogue, and its cap (maximum gain = 1, never
  amplify) on the music/FX path.
* **`sidechaincompress` / ducking** — A compressor triggered by a *different* signal from the one it
  processes. Here voice drives music: as soon as dialogue is detected, everything else steps back.
* **Loudness / LUFS / EBU R128** — A broadcast standard for perceived loudness across a whole
  programme, in LUFS, weighted for the ear's frequency response. It is what allows films to be
  compared and a reproducible target to be hit (-16 LUFS for the produced track).
* **LRA** — *Loudness Range*, in LU: how spread out loudness is across the programme. The script
  measures it before and after to confirm the range was tightened.
* **True peak / dBTP** — The real maximum of the reconstructed analogue waveform, which can exceed
  the maximum sample value. Headroom is kept (-1.5 dBTP) because lossy codecs overshoot slightly;
  without it you get distortion on playback.
* **Limiter** — A brick wall at the end of the chain that simply refuses to let the signal exceed a
  ceiling. The safety net after the final gain is applied.
* **High-pass filter** — Passes treble, cuts bass below a given frequency (40 Hz here), so inaudible
  infrasound does not drive the compressors for nothing.
* **AAC / bitrate** — The lossy codec used for the produced track, at 192 kb/s in stereo: transparent
  at that rate for a film soundtrack, and playable everywhere.
* **MKV (Matroska)** — A container format. It encodes nothing itself; it packs video, several audio
  tracks, subtitles and chapters into one file — which is what lets a stereo track sit alongside the
  5.1 without duplicating the movie.
* **ffmpeg** — The free command-line toolkit doing all the decoding, filtering and encoding. The
  script only measures, computes gains, and builds the right command lines.

## Notes

Design notes, measurements and the reasoning behind every setting are in
`CONVERSION-STEREO-NOTES.md` (in French).

## License

GNU Affero General Public License v3.0 or later (`AGPL-3.0-or-later`) — full text in
[`LICENSE`](LICENSE).

In short: you may use, study, modify and redistribute this script freely, provided derivative works
stay under the same licence and keep their source available — including when they are only made
available to users over a network, which is what the Affero clause (section 13) adds to the plain
GPL.
