# fleet-ops

The machinery that runs a fleet of 97 public repositories without a person in the loop: 47 self-hosting templates, 8 Terraform pipelines, a published image and the tools around them. It lives in GitHub Actions, reads every repository twice a day, moves what upstream moved, proves the move on a real deployment, cuts the release, and says out loud when it cannot decide. Every rule in it was shown a real violation before it was trusted, and the tests here plant those violations again on every push.

What it produces is public: [heyvaldemar.com/evidence](https://heyvaldemar.com/evidence/) carries the numbers it counts each morning, [heyvaldemar.com/ledger](https://heyvaldemar.com/ledger/) the findings that shaped it, and [heyvaldemar.com/decisions](https://heyvaldemar.com/decisions/) the trade-offs it embodies.

## What runs, and when

| Workflow | Cadence | What it does |
|---|---|---|
| [Fleet Triage](.github/workflows/fleet-triage.yml) | twice a day | Reads every template's freshness verdict. For a digest repush or a patch release it reads the upstream release notes through Claude, writes a verdict, moves the pin, and pushes. The next run reads that push's CI answer: green cuts a release, red reverts, anything else is left in place and judged as HEAD. Minor and major versions are prepared on a branch and handed to a person. A failed run is rerun once if the log says a registry refused it, and never twice. |
| [Fleet Heartbeat](.github/workflows/fleet-heartbeat.yml) | twice a day | Asks whether the watchers are still watching: every scheduled workflow in this repository and in the fleet, whether it fired inside its own interval, whether a push workflow is red on main, whether every repository carries the standard files and branch rules, whether every URL in every security policy answers. Findings go to one issue thread that is mailed only when the set of findings gains one. An external dead-man switch expects its ping, so GitHub not running this at all is also visible. |
| [Fleet Conformance](.github/workflows/fleet-conformance.yml) | daily | Asks a different question from CI: not "did it pass" but "does this repository still meet the standard". Digest pins, a restart policy on every service, every variable the compose needs present in the file people copy, every restore script actually run by a test, every prune actually exercised. Each rule is broken on purpose in `tests/test-conformance.sh` before the check runs. |
| [Fleet Catalog](.github/workflows/fleet-catalog.yml) | daily | Recounts the fleet and rewrites the catalogue, the profile's evidence line and `fleet.json`, which the website reads. It repeats OpenSSF Scorecard's result and the OpenSSF Best Practices badge, low marks included, rather than awarding itself a number. Nothing is committed when only the timestamp changed. |
| [Fleet Lifecycle](.github/workflows/fleet-lifecycle.yml) | weekly | Reads every pinned upstream's end-of-life date and names what is about to be unsupported, with the waivers held on purpose printed beside it so they cannot become something nobody remembers deciding. |
| [Fleet Scout](.github/workflows/fleet-scout.yml) | weekly | Ranks the self-hosting catalogue for the next template worth writing, and remembers what was declined so it does not propose the same shortlist for ever. |
| [Verify](.github/workflows/verify.yml) | every push | Runs every suite under `tests/` and every linter at its default severity. |

The rollouts under `scripts/rollout-*.sh` are the one-shot waves that took the fleet from one state to the next: branch rules, security policies, signed releases, the badge, the prune test. Each one is idempotent and names what it left alone.

## The rules it runs on

- **A check that cannot fail is not a check.** Every rule has a test that plants the violation and fails if the rule stays quiet. `tests/` holds 470 such cases.
- **A cause is a claim until the isolating run passes.** A red run is rerun once when the log names a registry refusal; a second failure is a signal, not a flake.
- **Only a red answer reverts.** A pushed refresh is judged by the workflow that verifies it. Skipped, cancelled and running are not verdicts.
- **A number the fleet awarded itself is a claim; one measured by a third party is a measurement.** Scorecard and the Best Practices badge are read from their sites every morning and repeated, low marks included.
- **A wait for a number is an assumption; a wait for the event is a test.** The prune test polls for the prune, with a ceiling of two cycles, and prints how long it took.
- **A list by hand falls behind the files it describes.** The workflows this repository carries are named in `scripts/expected-workflows.txt`, and a difference between the list and the checkout is a finding.

Each of these has a date and a failure behind it. The [ledger](https://heyvaldemar.com/ledger/) has all of them.

## What is not here

This repository is the public copy of the one that acts. The private one also reads two home servers' configuration mirrors and files what they taught the fleet; those two scripts, their tests and their reports stay private because they name what runs in a house. Everything else is here, and `scripts/export-public.sh` is the gate: it refuses the whole export if any published file matches a line of `scripts/public-deny.txt`, and `tests/test-export-public.sh` plants a hostname and a private address to prove that it does.

The private copy's history is not here either. It starts in April 2026 and carries every wrong turn; the ledger tells that story in fewer words than `git log`.

## Running it yourself

The workflows need one secret, `FLEET_PAT`: a fine-grained token with Contents, Actions, Issues and Pull requests read and write on the repositories the fleet manages. `HEARTBEAT_PING_URL` is optional and is the dead-man switch's address; unset, the heartbeat says so rather than passing quietly.

A copy that should read everything and push nothing sets the repository variable `FLEET_REHEARSAL=true`. This is how a new copy is proven beside the one that acts.

```bash
./tests/test-heartbeat.sh
./tests/test-triage.sh
./tests/test-conformance.sh /path/to/a/conforming/template
FLEET_LOCAL_DIR=/path/to/your/repos python3 scripts/fleet-conformance.py
```

Commits the fleet pushes are authored as the maintainer, with plain commit messages, the same convention as manual pushes. An AI agent does most of the typing across the fleet, and nothing it writes ships on its word: a release is cut only after the release commit itself deploys, backs up and restores in CI, and every rule here is tested against a planted violation before it is trusted.

## License

MIT. See [LICENSE](LICENSE). Security reports: [SECURITY.md](SECURITY.md).
