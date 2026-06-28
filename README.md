# Rukiki

Rukiki is an experimental simple-mode interface for [Nikki](https://github.com/nikkinikki-org/OpenWrt-nikki) and Mihomo on OpenWrt.

The goal is to make split routing understandable for ordinary users:

1. Paste a VPN subscription URL.
2. Let the router update the subscription automatically.
3. Let Mihomo select the fastest available node.
4. Route blocked or unavailable services through VPN.
5. Keep ordinary traffic direct.

> [!WARNING]
> Rukiki is in early development.
> It is not ready for production routers yet.
> Do not install it on a router that you cannot easily recover.

## Project status

Current status: **experimental prototype**.

Already implemented:

- separate `luci-app-rukiki` package;
- UCI configuration for simple mode;
- projection from Rukiki settings to Nikki configuration;
- automatic proxy groups:
  - `AUTO`;
  - `MANUAL`;
  - `PROXY`;
- custom domain rules;
- LuCI page named `Smart VPN`;
- RPC interface for apply, status, checks and tests;
- safe apply script with rollback;
- syntax checks for ucode sources;
- automated projection tests in GitHub Actions.

Not implemented or not validated yet:

- installation package for all target OpenWrt versions;
- full testing on GL.iNet Flint 2;
- production-ready DNS profile;
- automatic Russian blocklists and unavailable-service lists;
- MRS rule aggregation pipeline;
- watchdog and health recovery;
- package migrations;
- stable release and update channel.

## Architecture

Rukiki does not replace Nikki.

Nikki remains the owner of the active Mihomo runtime configuration. Rukiki acts as a simple configuration layer that generates the required Nikki inputs.

```text
LuCI Smart VPN
      |
      v
/etc/config/rukiki
      |
      v
Rukiki generator
      |
      +--> Nikki UCI settings
      |
      +--> Nikki mixin configuration
                 |
                 v
              Mihomo
```

This separation is intentional:

- Nikki keeps control over service startup, networking and nftables;
- Rukiki only manages the simple user scenario;
- advanced Nikki functionality remains available;
- upstream Nikki updates can still be merged into the fork.

## Target user scenario

The intended final workflow is:

1. Open OpenWrt LuCI.
2. Go to `Smart VPN`.
3. Paste a subscription URL.
4. Enable automatic node selection.
5. Enable smart routing.
6. Save and start.

The router should then:

- update the subscription automatically;
- test available nodes;
- select a working low-latency node;
- switch nodes after failure;
- send blocked resources through VPN;
- send Russian banks, government services and local networks directly;
- keep all other traffic direct by default.

## Routing model

The planned routing priority is:

```text
User DIRECT rules
User VPN rules
Local networks -> DIRECT
Russian allowlist -> DIRECT
Blocked resources -> PROXY
Unavailable-from-Russia resources -> PROXY
Optional service categories -> PROXY
Russian destinations -> DIRECT
Everything else -> DIRECT
```

User rules must always have higher priority than downloaded lists.

## Subscription handling

The subscription is intended to be used as a Nikki/Mihomo proxy provider.

Planned requirements:

- automatic updates;
- timeout and size limits;
- redirect handling;
- validation before apply;
- preservation of the last working subscription;
- no replacement with an empty or invalid response;
- masked secrets in UI and logs;
- no full subscription URL in diagnostic output.

## Automatic node selection

The generated configuration uses three logical groups:

- `AUTO` uses `url-test` to select the fastest available node;
- `MANUAL` allows explicit node selection;
- `PROXY` is the routing target used by rules.

The default intended mode is:

```text
PROXY -> AUTO
```

## Rule lists roadmap

The final system should automatically maintain multiple categories of rule sets:

- resources blocked in Russia;
- resources unavailable from Russian IP addresses;
- YouTube and Google Video;
- Discord;
- AI services;
- social networks;
- foreign media services;
- Russian banks and government-service allowlists;
- user-defined exclusions.

Candidate data sources include Antizapret, Re:filter, antifilter, ITDog and compatible Mihomo rule-set projects.

No source is treated as absolute truth. Before use, every source must be evaluated for:

- update frequency;
- accuracy;
- false positives;
- format;
- license;
- redistribution terms;
- mirrors;
- long-term reliability.

The preferred future design is to aggregate and validate lists in GitHub Actions, publish verified MRS files, and let routers download only ready-to-use artifacts.

## Reliability principles

Rukiki is designed around fail-open behaviour for home users.

If VPN configuration fails, ordinary direct internet access should remain available.

Required safeguards:

- validate generated configuration before restart;
- keep the previous working configuration;
- apply changes atomically;
- roll back after failed startup;
- reject empty subscriptions and rule sets;
- avoid secret leakage;
- keep custom user rules across updates.

## Security

A subscription URL is a secret and may grant access to a VPN account.

Rukiki must:

- avoid logging full subscription URLs;
- mask secrets in LuCI and diagnostics;
- validate allowed URL schemes;
- avoid shell interpolation of user input;
- restrict access to configuration and RPC methods;
- prevent subscription URLs from entering support archives;
- limit download size and execution time;
- avoid unsafe access to local or metadata endpoints.

## Repository layout

Important project paths:

```text
luci-app-rukiki/
├── Makefile
├── htdocs/
├── root/
│   ├── etc/config/rukiki
│   ├── etc/rukiki/ucode/generate.uc
│   ├── usr/libexec/rukiki/apply
│   └── usr/share/rpcd/ucode/luci.rukiki
└── po/

tests/
├── conftest.py
├── dump.uc
└── test_projection.py

.github/workflows/
└── rukiki-tests.yml
```

## Development

Run the projection tests through GitHub Actions.

The workflow:

1. builds the OpenWrt ucode toolchain;
2. verifies the `uci`, `fs` and `ubus` modules;
3. checks ucode syntax;
4. runs the Python projection test suite.

Local macOS runs may be unavailable without a compatible ucode and OpenWrt library toolchain.

## Planned development stages

### Stage 1: package build

- include `luci-app-rukiki` in package workflows;
- build an OpenWrt package for the target Flint 2 platform;
- inspect package contents and dependencies.

### Stage 2: router prototype

- install on a test Flint 2;
- verify LuCI rendering;
- verify subscription processing;
- verify generated groups and rules;
- verify Nikki startup;
- verify rollback.

### Stage 3: rule distribution

- create a separate list-aggregation pipeline;
- normalize and validate sources;
- build MRS artifacts;
- publish versioned releases;
- add safe updates on the router.

### Stage 4: networking hardening

- finalize DNS integration;
- define IPv6 behaviour;
- add health checks;
- add watchdog and recovery;
- add migration tests.

### Stage 5: release

- write installation and removal procedures;
- publish signed packages;
- add update and migration documentation;
- test upgrades from earlier versions;
- prepare a stable release channel.

## Upstream synchronization

This repository is a fork of the official Nikki project.

Upstream:

- [nikkinikki-org/OpenWrt-nikki](https://github.com/nikkinikki-org/OpenWrt-nikki)

Rukiki-specific changes should remain isolated where possible so that upstream updates can be merged with minimal conflicts.

Recommended remotes:

```shell
git remote add upstream https://github.com/nikkinikki-org/OpenWrt-nikki.git
git fetch upstream
```

Recommended synchronization:

```shell
git fetch upstream
git checkout main
git merge upstream/main
git push origin main
```

Always run the Rukiki test workflow after synchronizing with upstream.

## Credits

Rukiki is based on the official Nikki project and uses Mihomo as the proxy core.

Thanks to the Nikki and Mihomo maintainers and contributors.

This repository is an independent experimental fork and is not an official Nikki release.

## License

Rukiki follows the license of the upstream Nikki repository.

See [LICENSE](LICENSE).
