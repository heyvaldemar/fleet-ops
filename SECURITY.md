# Security Policy

fleet-ops is the automation behind the heyvaldemar template fleet: the daily triage of pins and failed runs, the conformance checks against the fleet standard, the catalog, and the lifecycle and release checks that feed them. It runs on GitHub Actions and ships no image or deployable template of its own.

## Supported versions

Only `main` is supported. Fixes land there; nothing is backported.

## Reporting a vulnerability

Report privately through GitHub: [**Security → Report a vulnerability**](https://github.com/heyvaldemar/fleet-ops/security/advisories/new) on this repository. Email to connect@valdemar.ai also works. The process is described at [heyvaldemar.com/security](https://heyvaldemar.com/security/).

You can expect an acknowledgment within 7 days. There is no bounty program; a valid, responsibly disclosed report gets public credit in the changelog.

Please do not open public GitHub issues for security reports.

## Scope

The workflows and scripts in this repository, including how they handle the tokens they run on. A problem in one of the templates belongs to that template's repository, which has its own policy.
