# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html):
a major version changes what the fleet does on its own, a minor one adds a
check or a job, a patch fixes one.

## [Unreleased]

### Changed

- **The weekly sweep of the house writes down only what could become a
  template change.** Its report listed every commit it had read, the host it
  came from and the model's verdict on each, local ones included: a weekly
  narrative of two home servers for the sake of the few rows that could move
  to a public repository. The mirrors hold the commits already. The report now
  carries the counts, the rows judged portable or already shipped, and the
  sections for the portable ones; everything judged local is a number.

### Fixed

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
