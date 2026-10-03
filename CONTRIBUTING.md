# Contributing

Bug reports, file types spacebar should open, and ideas go in
[issues](https://github.com/patebry/spacebar/issues/new/choose). In spacebar, **Settings › Report a Problem…** opens one
with your macOS and spacebar versions filled in. Security problems go to a [private
report](https://github.com/patebry/spacebar/security/advisories/new) instead ([SECURITY.md](SECURITY.md)).

## Pull requests

1. Fork the repository and branch from `main`.
2. Build with `./build.sh --no-install`, or `./build.sh` to try it in Finder ([Build from
   source](README.md#build-from-source)). Keep your signing identity in `.sign-id`, which is not tracked.
3. Run the off-screen tests from the README, and add a check for what you changed in the suite under `test/` that covers
   it.
4. Open the pull request against `main` and say what changes for someone using spacebar, and how you tested it.

Keep a pull request to one change. Every pull request is reviewed by the maintainer before it is merged; changes to the
installer and uninstaller (`scripts/`), signing (`build.sh`), the workflows (`.github/`) and the unsandboxed writer get
the closest reading, since they run with your files and permissions.

The extension takes no new dependencies unless they are vendored with their licence (see
`Preview/web/vendor/VERSIONS.txt` and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)), and spacebar makes no network
request of its own beyond the daily version check and an update you choose.

By sending a pull request you agree that your contribution is licensed under the [MIT licence](LICENSE), as spacebar is.
