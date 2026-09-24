# Contributing

A Swift 6 package that builds a macOS 14+ app. Everything below runs from a clone; no
account, no key, no network — beyond the first `swift build` fetching the package
dependencies (Sparkle).

## Build and test

```
swift build
swift test
```

The suite is hermetic — around 1,370 tests, none of which reach the network or spend a
penny of anyone's cloud credit. It takes well under a minute on an Apple Silicon Mac, so
run it before you push.

For the app bundle:

```
Scripts/build-app.sh            # build/Silicon Optimizer.app
Scripts/build-app.sh --release  # …optimised
Scripts/install-app.sh          # replace /Applications and reopen
```

`Vendor/` is gitignored and optional. When it is absent the bundle is built without the
embedded `llama-server` and Node — everything else works, and the app finds a `llama.cpp`
installed by Homebrew. `Scripts/verify-vendor-runtime.sh` checks a `Vendor/` you do have
against the committed digests.

## Pull requests get no automated checks here — run them yourself

The project uses no GitHub Actions or other hosted CI: every check is a script in this
repository, run on a Mac. So nothing turns green on your PR by itself. Run
`swift build && swift test` and say the result in the PR description, along with whichever
of these your change touches:

- `Scripts/test-video-node.sh` — the local video node under `Resources/video-node/`
- `Scripts/test-release-security.sh` — `Scripts/release.sh`, `Scripts/verify-vendor-runtime.sh`
  and the release supply-chain policy
- `node --test .github/skills/impeccable/scripts/security-hardening.test.mjs` — the
  Impeccable skill's scripts
- `Scripts/check-contract.sh`, `Scripts/verify-mcp.sh` and `Scripts/verify-cloud.sh` — the
  control API and the contract

`SILICON_NETWORK_TESTS=1 swift test --filter CatalogIntegration` checks the catalog against
Hugging Face. It depends on repositories this project does not control, so a failure there
is news about upstream rather than about your change.

## The contract is shared with two other repositories

`contract/` is the Mac↔node wire contract, the same bytes as in
[silicon-node](https://github.com/OGZamasu/silicon-node), and
[Silicon Buddy](https://github.com/OGZamasu/Silicon-Buddy) round-trips its types against a
copy exported from here by `ContractExportTests`. Editing a fixture in one repository and
not the others is how one contract quietly becomes two, so run
`Scripts/check-contract.sh` before pushing anything that touches it, and say in the PR
that the other repositories need the same change.

## House style

Read a neighbouring file before writing a new one. Comments here explain *why* a thing is
the way it is — the code already says what it does — and test names are sentences about
the behaviour they pin, not the function they call. New behaviour needs a test that fails
without it.

Never commit a real tailnet address, hostname, personal path or API key. Fixtures use
placeholders such as `100.64.0.9` and `/Volumes/External/Local Models`, and keys are
brought by the user and kept in the Keychain, never in the repository.

## Licence

By contributing you agree that your work is licensed under the [MIT licence](LICENSE) that
covers this repository.
