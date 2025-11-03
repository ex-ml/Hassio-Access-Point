# Changelog

## [0.5.4] - 2025-11-03

### Added
- Disable Internet access without host reboot: [#100](https://github.com/ex-ml/Hassio-Access-Point/pull/100)

## [0.5.3] - 2025-11-02

### Added
- Override HT capability: [#97](https://github.com/ex-ml/Hassio-Access-Point/pull/97)

## [0.5.2.1] - 2024-04-02

### Fixed
- Hotfix for a typo in the previous version
- Closes [#73](https://github.com/ex-ml/Hassio-Access-Point/issues/73) (Thanks for the issue, @muellermartin!)

## [0.5.2] - 2024-04-02

### Fixed
- Fixed repo to use LF again (my bad!)

## [0.5.1] - 2024-03-11

### Added
-  [PR-69](https://github.com/ex-ml/Hassio-Access-Point/pull/) (nice!!!) from [Hactys](https://github.com/Hactys): Added French translation for configs

## [0.5.0] - 2024-02-27

All changes for this version are in [PR-63](https://github.com/ex-ml/Hassio-Access-Point/pull/63) from [ROBOT0-VT](https://github.com/ROBOT0-VT) (New maintainer! =D).

### Added
- Validation for addon configuration menu
- English translations strings for more clear explanation of config options
    - Translations for other languages are welcome via pull request

### Changed
- Allow some addon config options to be optional
- Main script now uses `bashio` instead of `jq` to read config options
- Main script now uses `bashio` for checking of config options where feasible
- Config file has been converted to YAML format, for consistency with official HASSOS addons
- General cleanup

## [0.4.8] - 2023-10-19

### Fixed
- [PR-56](https://github.com/ex-ml/Hassio-Access-Point/pull/56) from [rrooggiieerr](https://github.com/rrooggiieerr): "Breaking Change: On Arm based boards network names are enumerated based on device tree. This means that the first Ethernet devices will no longer be named eth0 but end0. This pull request proposes a solution by using the default route interface to forward client internet access to."

## [0.4.7] - 2023-06-23

### Fixed
- IPtables dependency change as noted in [issue 42](https://github.com/ex-ml/Hassio-Access-Point/issues/42#issuecomment-1579294919). Thanks to [@tomduijf](https://github.com/tomduijf) for submitting [PR 48](https://github.com/ex-ml/Hassio-Access-Point/pull/48).

## [0.4.6] - 2023-04-23

### Bump to revert 0.4.5

## [0.4.4] - 2022-12-20

### Fixed
- [Issue](https://github.com/ex-ml/Hassio-Access-Point/issues/11) - Implemented changes detailed by @dingausmwald [here](https://github.com/ex-ml/Hassio-Access-Point/issues/11#issuecomment-1360142164)

## [0.4.3] - 2022-06-21

### Fixed
- [Issue](https://github.com/ex-ml/Hassio-Access-Point/issues/31) from @adosikas: `nmcli: command not found`. Added `apk add networkmanager-cli` to Dockerfile. Found this via [this PR](https://github.com/hassio-addons/addon-ssh/pull/415).

## [0.4.2] - 2022-06-14

### Added
- [PR](https://github.com/ex-ml/Hassio-Access-Point/pull/23) from @esotericnonsense (thanks!): Added a new config addon option: dnsmasq_config_override to allow additions/overrides to the dnsmasq config file, for example in order to add static DHCP leases with the dhcp-host= option. This option operates similarly to hostapd_config_override.

## [0.4.1] - 2021-07-21

### Added
- Allow DNS override for clients even if internet routing isn't enabled (allowing resolution of local hosts if the add-ons parent host doesn't have the correct DNS servers set).

## [0.4.0] - 2021-07-10

### Added
- Feature request: [Route traffic from wlan0 to eth0](https://github.com/ex-ml/Hassio-Access-Point/issues/5). Internet access for clients can be enabled with `client_internet_access: '1'`. If DHCP is also enabled, Hassio-Access-Point will try to get the parent host's DNS servers (not just container DNS servers), and server to clients as part of the DHCP config. This can be overridden with e.g. `client_dns_override: ['1.1.1.1', '8.8.8.8']`. If DHCP is not enabled, `client_internet_access: '1'` will still work, but DNS server will need to be set manually as with the rest of the IP config.

## [0.3.1] - 2020-10-21

### Fixed
- Conflict on port 53, as per [this issue](https://github.com/ex-ml/Hassio-Access-Point/issues/3). Added `port=0` to dnsmasq.conf as a fix (to disable DNS), but will explore expanding the DNS options as part of a future update.

## [0.3.0] - 2020-10-15

### Added
- Added a new config addon option: hostapd_config_override to allow additions/overrides to the hostapd config file (run.sh appends to the config file once everything else has been run, so for overriding an existing entry in the file, the later entry will take precedence). hostapd_config_override is a dictionary, so even if you're not overriding anything, `hostapd_config_override: []` must be in the addon options to allow you to save the addon config (if anyone knows how to make dictionaries optional, I'd love to know how..). Fix for [this](https://github.com/ex-ml/Hassio-Access-Point/issues/2).

## [0.2.1] - 2020-10-13

### Fixed
- [Issue](https://github.com/ex-ml/Hassio-Access-Point/issues/1) where AP started and clients could connect, but IP addresses were not being assigned. dnsmasq error: "dnsmasq: warning: interface wlan0 does not currently exist". This seems to be caused by the interface not having an IP address set. Not sure why this isn't being set via interfaces file, but added an ifconfig command to set address/subnet mask/broadcast address.

## [0.2.0] - 2020-09-25

### Added
- Add an debug option to addon config. debug=0 for mininal output. debug=1 to show addon detail. debug=2 for same as 1 + run hostapd in debug mode.

## [0.1.1] - 2020-09-23

### Removed
- Remove unnecessary docker privileges (SYS_ADMIN, SYS_RAWIO, SYS_TIME, SYS_NICE) from config.json
- Remove full access ("full_access": true) from config.json

## [0.1.0] - 2020-09-23

First release.

**Note**: This project was forked from [https://github.com/davidramosweb/hassio-addons](https://github.com/davidramosweb/hassio-addons/tree/f932481fa0503bf0f0b3f8a705b40780d3fe469a). I've submitted a lot of the functionality of this project back as a PR, but some of the extra stuff is outside the scope of a hostapd addon, so I'll leave it here for now as a more expandable hass.io access point addon.

### Added
- Allow hidden SSIDs (as per https://github.com/davidramosweb/hassio-addons/pull/6)
- Allow specification of interface name (defaults to wlan0) (as per https://github.com/davidramosweb/hassio-addons/issues/11)
- Added MAC address filtering
- Add DHCP server (dnsmasq)
- Enable AppArmor
- Add a basic icon/logo. Can do better...

### Changed
- Enabled wmm ("QoS support, also required for full speed on 802.11n/ac/ax") - have tested on mutiple RPIs, but needs further compatibility testing, and potentially moving option to addon config
- Remove interfaces file. Now generate it with specified interface name
- Remove /dev/mem mapping in config.json. Don't need memory access
- Remove RW access to config, ssl, addons, share, backup. Not required

### Fixed
- Remove networkmanager, net-tools, sudo versions (as per https://github.com/davidramosweb/hassio-addons/pull/15, https://github.com/davidramosweb/hassio-addons/pull/8, https://github.com/davidramosweb/hassio-addons/issues/14, https://github.com/davidramosweb/hassio-addons/issues/13)
- Corrected broadcast address (as per https://github.com/davidramosweb/hassio-addons/pull/1)
