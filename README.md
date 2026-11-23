# Veritwin Token Swap CLI

`veritwin` swaps tokens across chains through Veritwin's token swap service, from a terminal or a
script. It holds no keys: you sign every step yourself, in your own wallet on a signing page the CLI
serves on your machine, or with your own signer program (`--sign-with`).

## Install

**Alpha** (test networks):

```sh
# macOS, Linux
curl -fsSL https://veritwin.github.io/token-swap-cli/alpha/install.sh | sh
```

```powershell
# Windows (PowerShell)
irm https://veritwin.github.io/token-swap-cli/alpha/install.ps1 | iex
```

```sh
# npm (Node.js 22 or later)
npm i -g @veritwin/cli@alpha
```

**Prod**, from the first prod release on: the same addresses without `alpha/`, and
`npm i -g @veritwin/cli`.

The install scripts install a standalone build that brings its own Node.js: `~/.veritwin` and a
`veritwin` command in `~/.local/bin` (Windows: `%LOCALAPPDATA%\Veritwin`, with its `bin` folder on
your user PATH). Each script checks the download against the release's `SHA256SUMS` before it
changes anything. Builds exist for macOS (arm64, x64), Linux (x64, arm64; glibc) and Windows (x64,
arm64).

```sh
veritwin --version
```

## Use

The service needs an api key from Veritwin, given in the environment only (never as an option):

```sh
export VERITWIN_API_TOKEN=vtk_...
veritwin chains
veritwin tokens --chain sepolia
veritwin quote --from sepolia --to basesepolia --token USDC --amount 10
veritwin swap --from sepolia --to basesepolia --token USDC --amount 10
veritwin --help
```

A swap shows you the quote, with its Swap fee and exchange rate, and starts only once you accept
it. Transactions on a blockchain can't be undone.

## What it prints first

Every command starts with one line on stderr naming the build and the api it uses, e.g.:

```
Veritwin Token Swap CLI 0.1.0-alpha.0 *** alpha release *** (https://proto2.veritwin.com)
```

`--no-header`, or `VERITWIN_NO_HEADER=1`, turns it off. `veritwin --version` prints the same line.

## Updates

- `veritwin update` installs the newest release of your type; `veritwin update <version>` installs
  that version, an older one included. An npm install prints the npm command to run instead.
- Once a day, at a terminal, the CLI checks for a newer release of its type and says so on
  stderr. `VERITWIN_NO_UPDATE_CHECK=1` turns that off; it never runs in CI.
- Each CLI release needs the service's api at a matching version. If the api is older, or has a
  newer major version, the CLI says so and stops before it does anything else: update the CLI
  with `veritwin update`, or, for an older api, install an older CLI with
  `veritwin update <version>`.

## Environment

| Variable                   | Meaning                                             |
| -------------------------- | --------------------------------------------------- |
| `VERITWIN_API_TOKEN`       | your api key                                        |
| `VERITWIN_API_URL`         | another api than the build's own (also `--api-url`) |
| `VERITWIN_NO_HEADER`       | non-empty: no first line on stderr                  |
| `VERITWIN_NO_UPDATE_CHECK` | non-empty: no daily update check                    |
| `VERITWIN_HOME`            | where the install scripts put the CLI               |
| `VERITWIN_BIN_DIR`         | where they put the `veritwin` command               |
| `VERITWIN_BROWSER`         | the browser for the signing page (also `--browser`) |

## License

The Veritwin Token Swap CLI License (the `LICENSE` file): you may use the CLI for any purpose,
commercial included, but not change or redistribute it; each machine gets its copy from
Veritwin's own channels. The third-party components inside it keep their own licenses: see
`NOTICE` and the `licenses` folder.
