# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html):
a major version changes what the fleet does on its own, a minor one adds a
check or a job, a patch fixes one.

## [Unreleased]

### Added
- **Every `update.sh` stops on an env file it cannot read, and conformance
  requires it.** The new-variable check read `.env` (or the `.tfvars`) with
  `2>/dev/null`. An env file a restore had copied back as root:root 0600 made
  every value in it look unset, and with nothing new to check the checkout
  went ahead and the stack failed afterwards on the permission, with the tree
  already on the new tag. The guard names the file, its owner and mode, and
  stops before anything moves; it went to all 75 templates. Running the real
  script for that case found a second silent exit: the `${VAR:?}` search,
  under `pipefail` in a command substitution, ended the script with status 1
  whenever a release added a variable and no compose file required one, which
  is four templates today. `tests/test-update-sh.sh` runs both against the
  published scripts in a sandbox, and again with each fix taken out.

### Changed
- **Triage moves `.env.example` with the pin.** The commented `X_IMAGE_VERSION=` default now follows every version bump and every prepared major, the way the README already did. Conformance reports an example that names a version the compose file no longer pins; on 2026-09-30 fifty-four such lines across forty-two templates were found and fixed by hand.

- **The weekly sweep of the house writes down only what could become a
  template change.** Its report listed every commit it had read, the host it
  came from and the model's verdict on each, local ones included: a weekly
  narrative of two home servers for the sake of the few rows that could move
  to a public repository. The mirrors hold the commits already. The report now
  carries the counts, the rows judged portable or already shipped, and the
  sections for the portable ones; everything judged local is a number.

### Fixed
- **The upstream review reads the release a template already runs, as a
  baseline.** On 2026-10-06 the review of Rocket.Chat 8.8.1 to 8.9.0 read
  `MongoDB: 8.0` under the new engine versions, called it a mismatch with
  the template's MongoDB 7.0, and triage held the bump for a person. The
  8.8.1 notes carried the same line, the template had been running 8.8.1 on
  7.0, and the startup check that enforces the version was byte-for-byte
  unchanged: it exits only below 7.0. The review had only been shown the
  notes after the pin. It now also gets the pinned release's own notes, and
  a requirement that release already stated cannot decide the verdict.
  `tests/test-review-baseline.sh` covers the lookup and reads 8.8.1 live.
- **A run lookup that GitHub did not answer is no longer "CI never answered".** On 2026-10-05 kf2's digest refresh, green one minute after its push, was reported as unjudged after 16.8 hours, escalated to a person and dropped from the pending ledger, so its release was never cut: the lookup's own failure had been swallowed into an empty result. A failed lookup is retried once and, if GitHub still says nothing, the row is kept with no verdict for the next run. The planted test with a `gh` that refuses every call fails on the old code exactly as production did.
- **Every review source is proven by tag, and "GitHub did not answer" is no longer "absent".** `scripts/verify-mapping.sh` accepts a mapping only when the repository exists under exactly that name and carries the pinned version as a tag, and exits 0 proven, 1 disproven, 2 no verdict. `tests/test-review-sources.sh` runs it on all 66 mappings against `PROVEN_AT`, the version that proved each, and shows it a missing repository, a redirect to another project, a missing tag, a good mapping and a refused credential. Proving them found four mappings that pointed at packaging repositories with no version tags (postgres, wordpress, xwiki, the Project Zomboid image), which the review had been reading as "no releases found"; they moved to NO_NOTES with where the notes actually live, and Nextcloud now reads nextcloud/server instead of nextcloud/docker.
- **Publishing refuses to revert a change made on the public copy.** Dependabot and its automerge work on the public side; the export is the private tree, so the next publish silently undid each bump and Dependabot reopened it a week later. On 2026-10-03 #9 (upload-artifact v7.0.1, upload-sarif v4.38.2) was merged there while the private copy still carried v5.0.0 and v4.38.1. `publish-public.sh` now asks, for every path it would change, who changed it last on the public side, and stops on anyone but the publisher, naming the path. The two pins are ported here.
- **A pre-release is never a bump, whatever the upstream feed calls it.** On 2026-10-02 requarks published Wiki.js 3.0.0-beta.617 without the pre-release flag, `releases/latest` named it, and triage prepared a branch to move the template onto a beta. A version with an alpha, beta, rc, preview, dev, nightly or snapshot suffix is now reported once and left alone; the Wiki.js freshness check reads the newest stable release instead of `releases/latest`.
- **A version bump moves the pin the alarm names, not every pin that shares the version.** On 2026-10-01 `itzg/mc-backup` went to 2026.9.3; the Minecraft server image, on its own release line, pinned the same 2026.9.2, and triage tried to move it to a tag that does not exist and asked a person about it. When a freshness alarm names its variable (`X_IMAGE_TAG is behind: …`), only that pin moves now.

- **The commit message goes through the export gate too.** The public copy
  is committed with the private commit's first line, and the deny list had
  never been asked about it: a hostname in a message would have reached the
  public history, where main cannot be rewritten. A message matching the
  list now refuses the publish and says so; the suite plants one.

### Added

- **The heartbeat reports a person outside the fleet who is waiting for an
  answer.** An issue or pull request opened by someone who is not the owner and
  not a bot, open for more than 48 hours, never answered or answered last by
  them, is a finding with its link. Keycloak #45 sat three days unanswered
  because nothing read the issue trackers; six planted cases show the rule
  telling a waiting person from an answered one, a fresh one, a bot and a pull
  request.

- **Fleet conformance requires every Traefik stack to take
  `TRAEFIK_READ_TIMEOUT`, `TRAEFIK_WRITE_TIMEOUT` and `TRAEFIK_IDLE_TIMEOUT`.**
  Traefik reads its static configuration from the command in the compose file,
  and an override can only replace that command whole. Forty of fifty stacks
  gave an operator no way to set the entry point's timeouts and nine used nine
  different names. Forty-five take the same three today, each stack's older
  name nested inside so it keeps working; the five holding a pending security
  refresh follow once the triage has released it. Two planted cases: a timeout removed
  and a timeout written as a literal.

### Changed

- **The profile's badge line says why seven public repositories are not
  registered.** The profile carried 97 public repositories, 90 registered for
  the badge and 88 under the standard, and nothing said how they relate; a
  careful reader could take three counts for three fleets. The line now says
  that the unregistered ones hold no code to rate.

### Fixed

- **The waiting-person rule no longer takes the fleet check down with it.**
  Its search named neither issues nor pull requests, which the search API now
  refuses with HTTP 422; on 27 September that one refusal ended the whole
  fleet check before it reported anything, and heartbeat issue #5 said so.
  It now asks once for issues and once for pull requests, and the suite's fake
  refuses a query that names neither, as GitHub does.

## [1.0.0] - 2026-09-26

The first public release. The templates have carried their own automation
since April 2026 and this repository has run them together since 1 September;
this is the same code, published with a clean history. What it
learned on the way is on the [ledger](https://heyvaldemar.com/ledger/), and the
trade-offs it embodies are the [decisions](https://heyvaldemar.com/decisions/).

### Added

- **Fleet Triage**, twice a day: reruns a run once when its log names a
  registry refusal; for a digest repush or a patch release reads the upstream
  release notes through Claude and writes a verdict, moves the pin, pushes, and
  judges that push at the next run: green cuts a release, a red run reverts,
  any other answer is left in place. Minor and major versions are prepared on
  a branch for a person.
- **Fleet Heartbeat**, twice a day: whether every scheduled workflow here and
  across the fleet fired inside its own interval, whether a push workflow is
  red on main, the standard files and branch rules, every URL in every
  security policy, and an external dead-man switch for the heartbeat itself.
- **Fleet Conformance**, daily: digest pins, restart policies, every variable
  the compose file needs present in `.env.example`, every restore script run
  by a test, every prune exercised by a test.
- **Fleet Catalog**, daily: the catalogue, the profile's evidence line and
  `fleet.json` for the website, with OpenSSF Scorecard and the OpenSSF Best
  Practices badge read back from their own sites.
- **Fleet Lifecycle** and **Fleet Scout**, weekly.
- **The rollouts** under `scripts/rollout-*.sh` that took the fleet from one
  state to the next, each idempotent and naming what it left alone.
- **Tests** for every rule, each planting the violation the rule exists for.
- **Signed releases**: an archive of the tag, a keyless Sigstore signature and
  SLSA build provenance on every release, by `release-assets.yml`.
