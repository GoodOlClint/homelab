# Research: AI assistant for the Plex stack (prior art + gap analysis)

Date: 2026-07-24
Method: deep-research workflow — 5 search angles, 21 sources fetched, 104 claims extracted, 25 adversarially verified (16 confirmed / 9 refuted), plus unverified single-source claims marked below.
Question: does an AI/LLM assistant that (a) tunes transcode/streaming settings from playback history, (b) models per-client device capability, and (c) QAs existing library files already exist — and if not, what's the gap?

## Verdict

Nothing does this end-to-end. But two of the three layers you'd need already exist and should not be rebuilt. The genuine greenfield piece is the **decision layer in the middle**: join observed per-client transcode telemetry to a device-capability model and emit a target-format policy that an existing executor applies.

Also important: **your part (3) — A/V sync and subtitle QA — is where the research says be careful.** Automated desync detection is not a solved problem, and the accuracy numbers are bad enough that this should be an advisory/triage feature, never an automatic remediation one. Details in "Feasibility limits" below.

## What already exists

### Layer 1 — LLM/MCP access to Plex/Tautulli/*arr: already built several times over

| Project | What it is | Adoption |
|---|---|---|
| [lodordev/mcp-tautulli](https://github.com/lodordev/mcp-tautulli) | MIT, single 49KB Python file, on PyPI (v1.3.1, 2026-07-24). 19 MCP tools incl. `tautulli_stream_data`, `tautulli_transcode_stats`, `tautulli_platform_stats`. Handles `transcode_decision`, `transcode_hw_encoding/decoding`, bitrate, resolution. **Read-only by design.** | 5 stars, single author, ~4 months old |
| [niavasha/plex-mcp-server](https://github.com/niavasha/plex-mcp-server) | MIT TypeScript, 189 commits, unified Plex + Trakt + *arr MCP server, 12 vitest files + CI. Its "recommendations" are *content* recommendations (what to watch). | 38 stars |
| [wyattjoh/media-server-mcp](https://github.com/wyattjoh/media-server-mcp) | Radarr/Sonarr/Plex/TMDB. Plex coverage is library browse/search only — no `/status/sessions`, no `/clients`, no `/:/transcode`. | last push 2026-05-18 |
| [eddmann/plex-mcp](https://github.com/eddmann/plex-mcp) | Laravel MCP, 2 tools: active sessions + OpenSubtitles lookup, for spoiler-safe recaps. | 3 stars, personal |
| [omiron33/clawarr-suite](https://github.com/omiron33/clawarr-suite) | Advertises "180+ subcommands" over the whole *arr stack. Verification found its sole Tautulli integration is a 9KB `analytics.sh` calling `get_activity`/`get_history`/`get_home_stats`; it prints `transcode_decision` as a raw passthrough with no aggregation. | README overstates badly |

Also found: `vladimir-tutin/plex-mcp-server`, `BerryKuipers/mcp_services_radarr_sonarr`, `bdfrost/mcp-servarr`.

**Every one of them stops at descriptive reporting.** None contains a recommendation engine, a device-capability model, or codec/container direct-play decision logic. Verified by grep, not by README: `niavasha/plex-mcp-server` has *zero* source hits for `transcod|bitrate|bandwidth|hwaccel|direct ?play`; `mcp-tautulli` has no `prompts/`, `rules/`, or `profiles/` dir that could hold heuristics; `clawarr-suite`'s 44KB `dashboard.sh` has zero transcode/bitrate/codec references. The `eddmann/plex-mcp` author writes that transcode status is available from the session endpoint but "not required for this current use-case".

A design lesson from this cohort: one server ships 70 tools and had to add a 6-profile system (18–70 tools) to keep the context manageable. Tool-count explosion is real; expose workflow verbs ("find transcode-heavy clients"), not REST wrappers.

### Layer 2 — file-side execution: mature, don't rebuild

[**ptr727/PlexCleaner**](https://github.com/ptr727/PlexCleaner) — MIT C#/.NET, created 2020, ~1,718 commits, 337 stars, stable 3.21.27 with pre-releases days old. Description verbatim: "Utility to optimize media files for Direct Play in Plex, Emby, Jellyfin, etc."

Covers, already: remux to MKV, re-encode incompatible codecs, deinterlace, strip embedded closed captions, set/verify track language tags, dedupe audio/subtitle tracks, folder monitoring, and integrity verification with auto-repair (`Verify`, `AutoRepair`, `DeleteInvalidFiles`, `RegisterInvalidFiles`), lossless non-monotonic-DTS timestamp rewriting via `setts`, and detection/remux of unusable Matroska seek indexes that break Direct Play despite passing tool checks. Dependencies: MediaInfo, MkvToolNix, FFmpeg, HandBrake, 7-Zip.

**But every decision comes from a static JSON rule list with one global target format.** Inputs are user-editable arrays in `PlexCleaner.json` (`ReEncodeVideo`, `ReEncodeAudioFormats`, `KeepLanguages`, `PreferredAudioFormats`). Documented defaults are broad generalizations (MPEG-2 → H.264, VC-1 → H.264, Vorbis/WMAPro → AC3). Two independent fetches found **zero** mention of the Plex API, Tautulli, playback history, or watch statistics — the "Plex" in the name is the target platform, not an integration. There is no per-client profile system; one profile governs the whole library. `MaximumBitrate` is a verify/warn threshold, not a re-encode trigger.

Operational risk to note before adopting it: it modifies files **in place** (back up first), quickscan inspects only the first 3 minutes for interlacing/closed-captions with an acknowledged risk of missing later content, and the general `AutoRepair` path repairs by **lossy re-encoding** (only the DTS timestamp path is explicitly lossless).

Alternative executors named in your question but *not* independently verified in this pass: **Tdarr** (does ship first-class video health checking as a scalable job type — Transcode CPU/GPU + Health Check CPU/GPU workers, a natural fit for a 3-node Proxmox cluster; decision logic is a conditional JavaScript plugin stack), **Unmanic**, **FileFlows**. Tdarr's analytics operate on file/stream metadata only — no Plex or Tautulli playback history ingestion.

### Layer 3 — device capability knowledge: exists, but fragmented and partly stale

- **Plex client-profile XML** is the real mechanism: per-device XML files dropped in the server's `Profiles/` directory, matched by exact filename to the client identity string (`Android-SHIELD Android TV.xml`, `Chromecast.xml`). A profile encodes exactly what a capability model needs — `DirectPlayProfiles` (containers/video codecs/audio codecs played natively), `TranscodeTargets`, and `CodecProfiles` with hard limits (max resolution 3840x2160, bit depth, per-codec bitrate ceilings — the Chromecast profile caps at 75000 kbps). So bitrate/codec limits are already declaratively expressible without new formats. Install path differs by container image (hotio: `/appdata/plex/Profiles`; LSIO: `/appdata/plex/database/Library/Application Support/Plex Media Server/Profiles`) — an error-prone manual step automation could own. *(single-source, unverified)*
- **The community profile collection is stale and narrow** — last updated 2021-06-15, covers only Shield and Chromecast (no Apple TV, Roku, LG webOS, iOS/Android, browsers), explicitly untested on newer hardware. *(single-source, unverified)*
- **Jellyfin's codec-support matrix** ([docs](https://jellyfin.org/docs/general/clients/codec-support/)) is genuinely maintained (last touched 2026-01-29) with three per-client tables (video / audio / container) using three-state cells plus footnoted conditions (e.g. HEVC decode needs Apple A8X+ and iOS 14+). **But it is Jellyfin-scoped**: no LG webOS, no Chromecast, no Plex clients — and its subtitle table is format×container, not per-client. Useful as a shape to copy, not as a data source. *(verified 3-0)*
- **TRaSH Guides** maintains a "What does my media player support?" page and a Plex profiles page. Surfaced by search, not independently verified in this pass.

## Feasibility limits — read this before scoping the QA features

**A/V desync detection from content is not solved.** On AV-SyncBench (July 2026), the best model on the global-offset task — Synchformer — reaches **0.583 accuracy**; ImageBind sits at 0.505, i.e. chance. Accuracy degrades as the offset shrinks: Synchformer scores 0.510 at 50 ms vs 0.662 at 500 ms. A separate evaluation on 400 videos (200 clean, 200 audio-shifted) put **SparseSync at 42.3% and PEAVS at 50.5%** — an off-the-shelf desync checker would be wrong roughly half the time on a binary clean/desynced call. Models detect local jitter (CAV-MAE 0.768) and speed changes (SparseSync 0.707) far better than a **constant global offset**, which is the most common real-world defect. And all of these benchmarks are validated on clips **under 13 seconds** — nothing covers long-form content or drift across a full feature. *(unverified single-source arXiv claims — the verification pass never reached them; treat as directional)*

The tolerance you'd need to hit is tight: ITU-R BT.1359 detectability is +45 ms to −125 ms of audio leading video; EBU R37 requires +40 ms / −60 ms. That's 1–3 frames at 24–30 fps. Perception is also **asymmetric** (audio-early is more annoying than audio-late, so the window must be signed) and **strongly content-dependent** — the 50-point acceptability threshold is 200 ms for a newsreader but 500 ms–1.3 s for sports, a ~6.5× spread. One fixed threshold across a mixed library will be simultaneously too strict for action and too lax for dialogue. (Caveat: that per-content data comes from a 20-subject in-lab study — indicative, not robust.)

**Subtitle sync, by contrast, is genuinely tractable** — and already shipped:
- **Bazarr** already does audio-based subtitle sync (extracts the audio track, detects speech fragments, aligns) — same technique class as ffsubsync/alass, automatic on a configurable score threshold, runnable against existing subtitles. Its docs warn it causes "massive network and CPU usage" and recommend disabling on constrained hardware. Also relevant to any library-wide QA design: Bazarr notes that probing *inside the container* to inventory embedded subtitle tracks is the resource-intensive step. **The probe is the cost center, not the decision logic.**
- **alass** self-reports 88–98% "good subtitles", with a published error distribution: 50% within 50 ms, 80% within 100 ms, 90% within 400 ms, 95% within 800 ms — so ~10% remain off by >400 ms. It handles constant offsets *and* splits from ad breaks, director's cuts, and framerate mismatches, language-agnostically. Runtime ~10–20 s audio extraction + 5–10 s alignment per file — a whole-library sweep is feasible on homelab hardware.
- **ffsubsync** uses a single global offset from 10 ms VAD windows correlated by FFT; the maintainer states this covers >95% of cases, but mid-file edits (removed commercial breaks, inserted scenes, concatenated discs) are **explicitly unfixable** by a single offset. A reported failure on *Dune* produced a ~1-minute error (fictional languages confusing the VAD) — and the tool exposes **no confidence score**, so downstream automation cannot tell that a sync result is wrong.
- Baseline problem size: randomly downloaded OpenSubtitles.org subtitles had a ~50% error rate (N=118).

## The gap

```
[ Tautulli/Plex telemetry ]  →  ???  →  [ PlexCleaner / Tdarr executor ]
   already MCP-exposed        MISSING       already mature
        ↑
[ per-client capability model ]  ← exists as Plex profile XML + Jellyfin matrix,
                                   but not as a machine-consumable Plex-wide model
```

The missing piece is a **policy generator**: read observed per-client transcode telemetry, join it against a capability model, emit a target-format policy (and possibly the Plex client-profile XMLs themselves) that a deterministic executor applies.

Architecture recommendation from the synthesis: an LLM/MCP agent fits the **exploratory analysis and explanation** well — "why is the living-room Apple TV transcoding, what should I re-encode" — but the **enforcement path should stay a deterministic rules engine emitting config**, because the executor mutates files in place and its repair path is lossy. Don't put an LLM in the loop that rewrites media.

Corollary for the QA half: **A/V sync should be advisory-only** (flag suspicious files for human review, with a confidence score) given ~50% detector accuracy. Subtitle sync can be more aggressive — Bazarr already automates it — but wire in a sanity check, since ffsubsync exposes no confidence.

## Risk: everything here is single-maintainer

PlexCleaner is the outlier at 337 stars / 6 years / 1,718 commits — and still single-maintainer. mcp-tautulli: 5 stars, 2 forks, 0 watchers, created 2026-03-20. eddmann/plex-mcp: 3 stars, last push 2025-11-06. "Already built" ≠ battle-tested. And repeatedly in this ecosystem the README overstates what the code does — clawarr-suite advertised "deep integration" across 19 services while its scripts contain no transcode, device-profile, or QA capability. **Verify at source level before depending on anything here.**

This is also a fast-moving snapshot: mcp-tautulli shipped a release the day of this research, niavasha/plex-mcp-server was pushed the day before, PlexCleaner ships weekly. Any of these could add the decision layer within weeks.

## Open questions before committing to a build

1. Can **PlexCleaner be driven as the execution backend** — is `PlexCleaner.json` safely machine-writable per-library/per-title, and does its `IProcessPlugin` C# API (runtime assembly loading, unavailable in AOT builds) accept externally-computed per-file decisions? If yes, the new project is just a policy generator. If no, it's a full pipeline.
2. **Can Plex Media Server's own client-profile XMLs be read out of the server container** and used directly as the capability model, avoiding a hand-maintained matrix? This is the single highest-leverage unknown.
3. Where do **Tdarr / Unmanic / FileFlows** sit versus PlexCleaner here — their plugin systems may already support telemetry-driven rules. None was independently verified.
4. Does anything verify the **correct edition/version** is matched (your "right files are loaded" ask)? No surviving claim touched edition/version matching, mnamer, Profilarr, or *arr custom formats. Configarr covers TRaSH custom-format/quality-profile sync into Sonarr/Radarr and explicitly does no media QA.
5. What offset magnitude is **reliably detectable in practice** on long-form content? The benchmark data is all sub-13-second clips.

## Research caveats

- Part (4) of the question — accuracy limits — was **not** covered by the verified-claim set; the arXiv findings above are single-source and were dropped before the adversarial verification pass. Directional, not confirmed.
- Most findings are negative existence claims ("tool X does not do Y"), verified by reading repo trees plus the most relevant files, not every file (~9 of clawarr-suite's 24 scripts went unread). Residual risk low but nonzero.
- Nine claims were killed on adversarial vote — notably that mcp-tautulli's `transcode_stats` already solves transcode-heavy-client detection, and that clawarr-suite constitutes a unified LLM layer. Don't resurrect those.
- Never independently examined: Tdarr (beyond docs), Unmanic, FileFlows, mnamer, Profilarr, Radarr/Sonarr custom formats, edition/version matching.
