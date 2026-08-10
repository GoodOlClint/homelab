# Libation audiobook sync — change plan

**Status:** Fleet implementation parked until the post-MS-01 cutover (WP7). **An interim local instance is live on the operator's Mac** — see "Interim bridge" below. Nothing in the *fleet* scope of this plan is implemented.
**Decision record:** [ADR 0018](decisions/0018-audible-library-ingest-rides-libation-in-the-plex-services-stack-one-chapterized-m4b-per-book-staged-before-publish.md)
**Written:** 2026-08-02

## Goal

Purchased Audible titles land in the Plex library automatically, as one chapterized M4B per book, with no manual step after the initial account login.

## Why it is parked

`plex-services` is mid-migration. [ADR 0017](decisions/0017-guests-are-single-homed-on-the-services-vlan-storage-reaches-containers-via-host-bind-mounts.md) replaces per-guest NFS Docker volumes with host bind mounts, [ADR 0015](decisions/0015-durable-state-rides-detached-ceph-data-volumes-the-guest-rootfs-is-disposable.md) moves durable state onto a detached Ceph data volume, and [ADR 0003](decisions/0003-decompose-services-to-static-ip-lxcs-vms-only-where-isolation-demands.md) makes the guest a static-IP docker-LXC. Building against today's `plex_data` NFS volume would write lines with a known expiry and force the one-time interactive Audible login to be done twice. This plan lands with the WP4 service definitions.

## Interim bridge (live, outside the fleet)

The OpenAudible license expired on 2026-08-02, removing the only working archive path, so Libation was installed on the operator's Mac as a bridge until WP7. This is deliberately *not* fleet IaC — it is an unmanaged workstation install that retires at cutover.

- **Install:** `brew install --cask libation` (13.7.4). The cask symlinks `LibationCli` to `/opt/homebrew/bin/libationcli`, so the local instance and the eventual container share one CLI surface.
- **Config:** `~/Library/Application Support/Libation/Settings.json`. Keys set deliberately, all verified as real properties in the shipped assemblies rather than guessed: `Books` → `~/Audiobooks`, `FolderTemplate` → `<first author>/<title short> [<id>]`, `FileTemplate` → `<title short>`, `SplitFilesByChapter` → `false`, `AutoScan` → `true`.
- **Layout matches the WP7 target**, so the migration is a plain `rsync` into `/data/media/Audiobooks` with no restructuring: `Adrian Goldsworthy/The Fall of Carthage [1977330053]/The Fall of Carthage.m4b`.
- **Local disk, not the NAS, on purpose.** This is a laptop; pointing `Books` at an SMB share invites Libation writing into an empty mountpoint whenever the share is not mounted, silently splitting the archive across two places.
- **Staging is native.** Libation's `InProgress` directory is its own download/convert staging area and it moves completed books to `Books` — the mechanism this plan specifies. Left at its default, which shares a filesystem with `~/Audiobooks`, so the move is atomic. **At WP7 this stops being free:** if `InProgress` and the published path land on different filesystems the move degrades to a copy and loses atomicity. Put them on the same filesystem, or do the publish step explicitly.
- **Scope honored:** the backfill was driven from an explicit ASIN list filtered to `IsAudiblePlus != true`, so the 10 Audible Plus (subscription-catalog) titles were excluded per ADR 0018. A bare `liberate` would have pulled them.

**Backfill completed 2026-08-02: 228 titles liberated, 0 failures.** Verified across every file, not a sample — all 228 carry embedded chapters (min 4, max 515, 9,216 total), and none is missing `album`, `artist`, `album_artist`, or embedded cover art. Those are the tags Audnexus matches on, so the metadata floor holds even if the agent turns out to be unavailable.

**Sizing, measured rather than estimated: 145 GB for 3,317 audio-hours — ~45 MB per audio-hour.** Bitrate varies per title (64 kbps is common, some are higher), so a single-title sample understates the total badly; an early one-book measurement suggested ~28 MB/hr and was low by 60%. Use the 45 MB/hr figure when sizing the WP7 volume, and treat it as a floor rather than a ceiling — it grows with each purchase.

**Carrying this to WP7:** `libationcli export-master-key` exports the OS-bound key that unlocks `AccountsSettings.json`, which is the documented path for moving an existing authenticated config into the container. Doing that at cutover avoids repeating the interactive `login-external` bootstrap.

## Scope

| File | Change |
|---|---|
| `ansible/inventory/host_vars/plex-services.yml` | Add a `libation` entry to the `plex_services` dict — `image`, `PUID: 2013` (next free), `PGID`, `dbs: []`. No `db_user`, no `config`. |
| `ansible/roles/plex_services/defaults/main.yml` | `libation_image` pin, `libation_sleep_time`, staging path, published library path. |
| `ansible/roles/plex_services/templates/docker-compose.yml.j2` | One `libation` service block. |
| `ansible/roles/plex_services/tasks/main.yml` | Staging + published directory creation; publish-on-complete unit. |
| `ansible/roles/infisical_client/templates/secrets/plex-services-libation.env.tpl.j2` | Master-key delivery. |
| `ansible/playbooks/services.yml` | One `infisical_agent_templates` entry with a `post_command` recreating the container. |

No new role, no new repo, no new Infisical folder — `/plex-services` is already owned by the `plex_services` role.

## What the role already does for free

Verified against the current role, not assumed:

- `tasks/main.yml:150` creates a system user per `plex_services` key from its `PUID`.
- `tasks/main.yml:213` creates `/opt/plex-services/<key>` owned by that user; `tasks/main.yml:2444` re-asserts ownership at the end of the run.
- Every arr-specific loop — initial-config waiting, database creation, API-key extraction, root folders, download clients — is gated on `db_user`, `config`, or an explicit service list. A `libation` entry with none of those falls through all of them.

So adding the service is a host_vars entry plus a compose block. The role needs new tasks only for the staging/publish paths.

## Sequencing

1. **WP4, with the rest of the service definitions.** Add the host_vars entry, defaults, and compose block against the bind-mount model. Libation's `/config` (SQLite library database, encrypted account settings) goes on the data volume alongside the arr configs; staging goes on a disposable local path.
2. **Seed the master key.** `generate_secret.yml` into `/plex-services`, then the agent template and its `post_command`. Follows the existing convention exactly — no baked secrets in the compose template.
3. **One-time interactive bootstrap.** `docker exec` into the container, run `LibationCli login-external`, complete the URL in a browser, paste the redirect back, confirm with `list-accounts`. Once, against the final guest. This is a runbook step, never a role task.
4. **First liberate run, observed.** Let it converge on the existing library before enabling the poll loop, and watch storage on both the staging path and the media export.
5. **Create the Plex library.** Type Music, pointed at `/data/media/Audiobooks`. Attach Audnexus only if step 0 below confirms it is still attachable.
6. **Alerting.** Repeated auth failure raises on the existing ntfy channel ([ADR 0011](decisions/0011-two-alerting-lanes-uptime-kuma-for-reachability-alertmanager-for-metrics.md)). No retry-loop against an account-lockout surface.

## Verify before building — open questions, not assumptions

These are unverified as of writing and each can change the design:

0. ~~**Does current Plex Server still allow attaching a legacy plugin agent to a new library?**~~ **Resolved 2026-08-02 — moot.** The Plex Audiobooks library already exists as section 11, type `artist`, agent `com.plexapp.agents.audnexus`, scanner `Plex Music Scanner`, path `/mnt/media/Audiobooks`. At WP7 the existing section is repointed rather than a new library created, so the "can a legacy agent still be attached" question never has to be answered.
1. **Confirm the current Libation setting name and default for chapter splitting** — it must be *off*, and the setting has moved between releases.
2. **Confirm whether the pinned release still needs an occasional GUI-run migration.** If upstream has fixed it, the pin retires and the image returns to `latest` under the ADR 0016 convention.
3. **Confirm Libation's publish to the target filesystem is atomic**, or make the publish step do the atomicity itself.
4. **Name the post-cutover staging path.** `docs/rebuild-as-routine-design.md` gives `plex-services` a data volume for postgres and app configs but does not carry today's scratch disk forward.
5. ~~**Confirm which Plex clients in use expose embedded M4B chapter navigation.**~~ **Resolved 2026-08-02.** Clients are iOS; the recommended player is **Prologue** (free with a one-time $9.99 Premium IAP; iPhone/iPad/Apple Watch/CarPlay; requires iOS 18.1+). It reads embedded chapters natively, so the single-file decision holds. Plexamp and the stock Plex app are both unsuitable — native audiobook support in Plexamp remains an open Plex feature request, so books inherit music semantics.

## Open decision for WP7 — dedicated audiobook server vs Plex

**Deliberately parked on 2026-08-02, not resolved. Decide this before writing the WP4 fleet definitions, or it gets decided by default.**

The question: keep audiobooks in Plex, add **Audiobookshelf** alongside it against the same tree, or move to Audiobookshelf entirely. Evidence gathered so far:

- **21 of the 228 liberated books ship companion PDFs** (Norse Mythology, The Iliad, The Mathematics of Love, London, and 17 others). Plex's Music library type has no concept of a companion PDF, so these are **structurally unreachable in Plex** — not a configuration gap. Audiobookshelf detects them automatically as supplementary e-books and has a built-in pdf/epub reader.
- **Caveat that cuts against the switch:** Prologue is an audio player with no documented e-book reader on either backend. Moving to Audiobookshelf makes the PDFs *reachable* (ABS web UI / ABS apps), not visible inside Prologue. Whether that matters depends on whether a companion PDF is ever wanted mid-listen on a phone versus at a desk.
- Audiobookshelf carries first-party Audible/ASIN metadata providers, which would **retire the Audnexus legacy-agent dependency** rather than accept it as a standing risk.
- Prologue supports both backends (rebuilt for Audiobookshelf in 4.0), so the client story is unchanged for audio either way.
- **Nothing already built is at stake.** Single-file M4B with embedded chapters under `Author/Title [ASIN]/` is what Audiobookshelf wants too, so the 145 GB archive is portable to either backend. That decision was correct independent of this one.
- **The real cost is this fleet's per-service tax**, not the container: a guest, an Infisical entry, PBS backup, an Uptime Kuma monitor, a DNS name, a cert, and a remote-access path separate from the existing Plex/VPS-relay route.
- **Auth is the sharpest cost, and it is the reason to be sceptical of the switch.** Plex, Tautulli, and Seerr all authenticate against **Plex accounts natively** — that is why family members have exactly one credential today, and it does not depend on an IdP. **Audiobookshelf has no native Plex authentication.** It is therefore the first service in this fleet that would break the one-account property. Three ways out, none free:
  1. **Local ABS accounts.** Simplest to stand up, and it hands every family member a second username and password — precisely the thing the current design avoids.
  2. **Configure Authentik and federate.** ABS has first-class OIDC, and Authentik has a **Plex Source** with "Allow friends to authenticate", so the chain Prologue → ABS (OIDC) → Authentik → Plex Source → existing Plex account restores one credential. **But Authentik is deployed and entirely unconfigured** — the role and containers exist and `docs/authentik-setup.md` describes the manual web-UI setup, which has never been performed. Treat this as a separate project with its own gate, not a line item inside the audiobook work.
  3. **Stay on Plex**, accept that the 21 companion PDFs are unreachable in-app, and read them off the share when wanted.
- If option 2 is ever taken: use an **OAuth2/OpenID Connect** provider, *not* the Proxy/Forward-Auth provider `authentik-setup.md` specifies for Tautulli — forward auth breaks native apps, which cannot traverse the proxy redirect. Add Prologue's mobile redirect URI (`<appname>://oauth`) to ABS's **Allowed Mobile Redirect URIs**, keep a local ABS admin as break-glass (`?autoLaunch=0` reaches the local login form if the IdP is down), and verify early: Prologue's OIDC-to-ABS flow has a history of breakage, and ABS group/permission mapping from OIDC claims is undocumented, so per-user library and download rights may still need setting by hand.



## Test bar

Every change lands with a check that fails before it and passes after.

- **Idempotency:** a second `make ansible plex-services TAGS=plex-services` run reports zero changes. Non-negotiable, per repo convention.
- **`docker-config` path:** `make docker-config plex-services` renders and deploys the compose without the full role. This is the lightweight path the repo requires every service to survive.
- **No arr-loop bleed:** a run with the `libation` entry present produces no new tasks in the database, API-key, or root-folder loops. Discriminating: it fails if a future edit to those loops drops a `when` gate.
- **Staging isolation:** a book interrupted mid-conversion leaves nothing under `/data/media/Audiobooks`. Fails before staging exists, passes after.
- **No secret in the compose:** `grep` the rendered `/opt/plex-services/docker-compose.yml` for the master key — must be absent. gitleaks covers the repo side.

## Definition of done

A title purchased on Audible appears in the Plex Audiobooks library as a single chapterized M4B, under `Author/Title [ASIN]/`, without any manual step — and the operator can confirm it by buying a book and waiting one poll interval. Fails before the change (the book never appears); passes after.

## Out of scope

- Retro-tagging or reorganizing any existing audiobook files.
- Narrator/series metadata beyond what Libation embeds and Audnexus supplies.
- Subscription-catalog titles — purchased/owned only.
- Any per-chapter splitting pipeline.
