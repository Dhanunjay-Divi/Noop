# Homebrew Cask (macOS)

NOOP does **not** currently publish a Homebrew tap. Build the app from source,
or use a macOS artifact attached to a release in
[`Dhanunjay-Divi/Noop`](https://github.com/Dhanunjay-Divi/Noop/releases) once one
exists and the distribution gate passes.

## Publishing the project tap

Release maintainers may create a separate public
`Dhanunjay-Divi/homebrew-noop` repository. After it exists, users can install
with:

```bash
brew tap dhanunjay-divi/noop
brew trust dhanunjay-divi/noop
brew install --cask noop
brew upgrade --cask noop
```

Homebrew requires explicit trust for non-official taps. Inspect the short cask
before trusting it. The macOS release is ad-hoc signed rather than notarized, so
Gatekeeper may also require **System Settings → Privacy & Security → Open
Anyway** on first launch.

The release helper refuses to guess a tap owner. To update the project tap,
provide it explicitly:

```bash
NOOP_HOMEBREW_TAP_ORG=Dhanunjay-Divi \
  Tools/update-homebrew-cask.sh 9.1.1 dist/NOOP-macos-v9.1.1.zip
```

To opt the broader manual release helper into that step, also set
`NOOP_RELEASE_HOMEBREW=1`.

The helper:

- calculates the release ZIP's SHA-256 digest;
- generates `Casks/noop.rb` with downloads and homepage pointing to
  `Dhanunjay-Divi/Noop`;
- reads the GitHub token from `~/.config/noop/gh_token`;
- supplies credentials through a transient Git credential helper rather than a
  command-line URL; and
- never targets a Forge mirror unless `NOOP_HOMEBREW_FORGE=1` and all `FORGE_*`
  coordinates are supplied explicitly.

Scope the token to **Contents: read and write** on the project tap repository
only. Do not reuse a token from another project or repository.
