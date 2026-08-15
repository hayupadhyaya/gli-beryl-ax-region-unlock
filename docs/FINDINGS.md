# What the CN region code actually does

Everything here was measured on a GL-MT3000 (Beryl AX) running stock firmware
4.8.1, by capturing a full system snapshot in the `CN` state, changing the
country code to `CA`, and diffing the two.

**Headline: the CN firmware is not crippled. Nothing is removed.** Every VPN
package, kernel module and UI component is installed and present. The region
code only changes what the admin panel is willing to *draw*, plus one runtime
service gate.

---

## 1. What is installed on CN firmware

All of this is present on an untouched CN unit:

```
wireguard-tools          kmod-wireguard           openvpn-openssl
kmod-ovpn-dco-v2         zerotier                 tailscale (1.80.3)
gl-sdk4-wg-client        gl-sdk4-wg-server
gl-sdk4-ovpn-client      gl-sdk4-ovpn-server
gl-sdk4-vpn-client       gl-sdk4-vpn-policy
gl-sdk4-ui-wgclient      gl-sdk4-ui-wgserver
gl-sdk4-ui-ovpnclient    gl-sdk4-ui-ovpnserver
gl-sdk4-ui-vpndashboard  gl-sdk4-ui-tailscaleview gl-sdk4-ui-zerotierview
```

Note that even the **UI packages for the hidden pages are installed**. The
WireGuard client page ships on a CN device; the menu filter simply declines to
show it.

## 2. The UI gate

Each admin-panel page is described by a JSON file in `/usr/share/oui/menu.d/`.
The VPN pages carry a `lang_hide` key:

```json
// /usr/share/oui/menu.d/wgclient.json
{
    "view": "wgclient",
    "parent": "vpn",
    "lang_hide": ["zh-cn"],
    "show_mode": ["router"]
}
```

`tailscaleview.json` has no `lang_hide`, which is why Tailscale is visible on a
CN unit.

The filter that consumes it lives in `/www/js/app.*.js`. Deminified, the final
return is the region gate:

```js
return !(
    countryCode.toLowerCase().indexOf("cn") >= 0 &&
    lang_hide != null && lang_hide.includes("zh-cn")
)
```

A page is hidden only when **both** hold: the device country code contains `cn`,
and that page's `lang_hide` lists `zh-cn`. Despite the key's name this has
nothing to do with your selected interface language — an English UI on a CN
device still hides these pages.

A second, separate mechanism exists for per-country inclusion/exclusion:

```json
// /usr/share/oui/menu.d/astrowarp.json
"country": { "exclude": true, "codes": ["cn"] }
```

Because the check is `indexOf("cn") >= 0` — a substring match, not equality —
any country code *containing* `cn` triggers it. `CN` is the only real ISO 3166
code that does.

## 3. What is hidden on CN

Derived by reading every file in `/usr/share/oui/menu.d/`:

| Page | Menu location | Mechanism |
|---|---|---|
| VPN Dashboard | VPN | `lang_hide` |
| WireGuard Client | VPN | `lang_hide` |
| WireGuard Server | VPN | `lang_hide` |
| OpenVPN Client | VPN | `lang_hide` |
| OpenVPN Server | VPN | `lang_hide` |
| Tor | VPN | `lang_hide` |
| AdGuard Home | Applications | `lang_hide` |
| Dynamic DNS | Applications | `lang_hide` |
| AstroWarp / SD-WAN | Cloud Services | `country.exclude` |

Every child of the `VPN` parent is hidden, so the entire VPN top-level menu
disappears rather than appearing empty. Cloud Services keeps only GoodCloud.

AdGuard Home loses its dedicated Applications page but **still appears in the
Plugins list**, because the Plugins page enumerates installed packages rather
than menu entries.

Two further UI effects, observed rather than derived from the menu files:

- **The dashboard status row.** The router topology diagram carries a row of
  service icons. On CN it shows only `IPv6`; on a non-CN device it shows
  `AdGuard · IPv6 · VPN · Tor`.
- **The header badge.** The admin panel prints a `CN` chip next to the firmware
  version. After the change the chip disappears entirely rather than showing the
  new code — it is a "this is a China-region unit" marker, not a region display.

Screenshots of all of the above — header, dashboard and every affected menu —
are in the [README](../README.md#before-and-after).

## 4. What still works on CN, with no modification at all

Confirmed visible and usable on an untouched CN unit:

- **Tailscale** — full page under Applications. If Tailscale is all you want,
  a CN device needs no patching whatsoever.
- **ZeroTier** — full page under Applications.
- **AdGuard Home** — installable and manageable from the Plugins page.
- **GoodCloud** — the only remaining Cloud Services entry.
- NAS, Parental Controls, Plugins, and every Network and System page.

Beyond the UI: because `wireguard-tools`, `kmod-wireguard` and `openvpn-openssl`
are installed, **WireGuard and OpenVPN can be configured from the command line
or LuCI on a stock CN device** without touching the region code. What you lose
is GL's configuration UI for them, not the capability.

## 5. The one non-UI gate

`/etc/init.d/mptun` — GL's tunnel datapath — checks the region at every boot:

```sh
[ "$(get_country_code)" = "CN" ] && {
    uci set mptun.global.enable=0
    uci set mptun.global.use_exit=0
    uci commit mptun
    sync
    return 0
}
```

This is a strict equality against `CN`, unlike the UI's substring test. It means
a VPN configured through GL's own stack gets switched off again on every reboot
while the region is CN. A tunnel configured directly — plain `wg-quick`, or
OpenVPN via LuCI, bypassing GL's mptun layer — is unaffected.

This is also the only gate that reads `get_country_code()`, which is why the
UCI override in `/lib/functions/gl_util.sh` is enough to clear it:

```sh
get_country_code() {
    uci -q get board_special.hardware.country_code || cat /proc/gl-hw-info/country_code
}
```

## 6. Measured before/after

Full system snapshots in both states, diffed. Identical across `CN` and `CA`:

- the complete `opkg list-installed` output
- every init script's enabled/disabled state
- every module in `/usr/lib/oui-httpd/rpc/`
- every file in `/etc/config/`
- the entire `uci show` dump, except as noted below

The only differences were the country code itself (`/proc/gl-hw-info/country_code`,
the flash bytes, and `get_country_code()`), plus unrelated boot noise: kworker
thread names, avahi startup timing, a plugin-cache counter, and the guest/Wi-Fi
`macaddr` values that GL randomizes on every boot regardless of region.

**Changing the region code does not install, enable, start or unlock any
software.** It changes one string that the web UI reads to decide what to
render, and that `mptun` reads to decide whether to disable itself.
