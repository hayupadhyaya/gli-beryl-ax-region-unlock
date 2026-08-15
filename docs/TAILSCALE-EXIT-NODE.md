# LAN clients get no internet through a Tailscale exit node

**Symptom.** You select an exit node on a GL.iNet router. The router itself has
internet. Every device behind it does not — pages hang, apps time out, nothing
loads.

This has nothing to do with the region patch. It affects any GL.iNet router used
as a Tailscale exit-node gateway.

---

## Cause

GL's firmware creates a `tailscale0` firewall zone and wires up the
`lan ↔ tailscale0` forwardings, so packets **are** forwarded into the tunnel.
But it never enables masquerading on that zone:

```
zone_wan_postrouting        →  -j MASQUERADE     ✅
zone_tailscale0_postrouting →  (nothing)         ❌
```

Forwarding without NAT means client packets enter the tunnel still carrying their
private source address. The exit node has no route back to `192.168.8.x`, so
every reply is dropped. `conntrack` shows it plainly:

```
src=192.168.8.159 dst=17.248.199.65 ... packets=9 bytes=576 [UNREPLIED]
```

Nine packets out, zero back. The router is unaffected because its own traffic
already leaves with a valid `100.x.y.z` Tailscale source and needs no
translation — which is exactly why the router has internet while nothing behind
it does.

## Fix

```sh
uci set firewall.tailscale0.masq='1'
uci commit firewall
/etc/init.d/firewall reload
```

Confirm it took:

```sh
iptables -t nat -S zone_tailscale0_postrouting | grep MASQUERADE
```

Replies now return to the router's Tailscale address:

```
src=192.168.8.159 dst=9.9.9.9 ... packets=16
src=9.9.9.9 dst=100.64.0.1 ... packets=13 [ASSURED]
```

---

## Making it stick

The one-liner survives a reboot, but **GL's Tailscale service rebuilds that zone**
when you toggle Tailscale in the UI, and a firmware upgrade can reset it. On a
router you cannot walk over to, that is not good enough. Install
[`extras/tailscale-exit-node-masq.sh`](../extras/tailscale-exit-node-masq.sh),
which re-applies the setting at both config and live-iptables level and is safe to
run repeatedly.

It gets invoked from three independent places, so no single reset breaks it:

```sh
# 1. Every firewall reload.
#    /etc/firewall.user is a preserved package conffile (firewall.conffiles) and
#    is already registered as a firewall include.
scp -O extras/tailscale-exit-node-masq.sh root@192.168.8.1:/etc/firewall.user
ssh root@192.168.8.1 chmod +x /etc/firewall.user

# The stock include has no 'reload' option, and fw3 defaults that to 0 - meaning
# it runs only on a full restart, NOT on a reload. GL's services trigger reloads,
# so this flag is what makes the hook actually fire:
uci set firewall.@include[0].type='script'
uci set firewall.@include[0].reload='1'
uci commit firewall

# 2. Every time GL brings Tailscale up.
#    /usr/bin/gl_tailscale runs this exact path if the file exists:
#        if [ -f /etc/firewall.tailscale.sh ]; then /etc/firewall.tailscale.sh & fi
cat > /etc/firewall.tailscale.sh <<'HOOK'
#!/bin/sh
[ -x /etc/firewall.user ] && /etc/firewall.user
exit 0
HOOK
chmod +x /etc/firewall.tailscale.sh

# It is not a package file, so it needs to be listed to survive an upgrade.
# /etc/sysupgrade.conf is itself a preserved conffile.
grep -qxF /etc/firewall.tailscale.sh /etc/sysupgrade.conf || \
    echo /etc/firewall.tailscale.sh >> /etc/sysupgrade.conf

# 3. Every time an interface comes up.
#    A WAN change (DHCP renew, link flap, ISP reconnect) rebuilds the firewall in
#    a way that drops the rule WITHOUT running the firewall includes - observed
#    on 4.8.1 after a plain `ifup wan`. This is the hook that catches it, and on
#    a router at the far end of someone else's internet connection it is the one
#    that matters most.
mkdir -p /etc/hotplug.d/iface
cat > /etc/hotplug.d/iface/99-ts-exit-masq <<'HOTPLUG'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ -x /etc/firewall.user ] && /etc/firewall.user
exit 0
HOTPLUG
chmod +x /etc/hotplug.d/iface/99-ts-exit-masq
grep -qxF /etc/hotplug.d/iface/99-ts-exit-masq /etc/sysupgrade.conf || \
    echo /etc/hotplug.d/iface/99-ts-exit-masq >> /etc/sysupgrade.conf

# 4. A periodic backstop, for anything the others do not catch.
#    /etc/crontabs/ is in /lib/upgrade/keep.d/base-files.
echo '*/2 * * * * /etc/firewall.user >/dev/null 2>&1' >> /etc/crontabs/root
/etc/init.d/cron enable && /etc/init.d/cron restart
```

### Why four layers

| Layer | Survives | Recovers from |
|---|---|---|
| `firewall.tailscale0.masq` in `/etc/config/firewall` | reboot, keep-settings upgrade | nothing — it is the thing that gets reset |
| `/etc/firewall.user` | reboot, upgrade (package conffile) | the zone being rebuilt by a firewall reload or restart |
| `/etc/firewall.tailscale.sh` | reboot, upgrade (via `sysupgrade.conf`) | Tailscale being toggled in the GL UI |
| `/etc/hotplug.d/iface/99-ts-exit-masq` | reboot, upgrade (via `sysupgrade.conf`) | WAN reconnects, DHCP renewals, link flaps |
| cron every 2 min | reboot, upgrade (`keep.d`) | anything else, within two minutes |

The hotplug layer was not in the original design. It was added after testing showed
that `ifup wan` silently dropped the rule **and produced no healer log entry at
all** — none of the firewall hooks fired for that path. If you are adapting this,
do not assume a firewall include covers interface events; it does not.

Nothing survives a firmware upgrade that does **not** keep settings, or a factory
reset. After either, re-run the install above. (The region patch itself is
unaffected — it lives in the Factory partition.)

### Verifying it works

Deliberately break it and watch it come back:

```sh
uci -q delete firewall.tailscale0.masq && uci commit firewall
iptables -t nat -D zone_tailscale0_postrouting -j MASQUERADE
/etc/init.d/firewall reload && sleep 4
iptables -t nat -S zone_tailscale0_postrouting | grep MASQUERADE   # back
logread | grep ts-exit-masq                                        # says why
```

Tested on GL-MT3000 firmware 4.8.1. Each path was broken deliberately and
confirmed to heal: firewall reload, firewall restart, the Tailscale hook, an
`ifup wan`, the cron path, and a reboot with the config setting deleted
beforehand.

### DNS

While you are here, pin the upstream resolvers rather than inheriting whatever
the upstream network hands out. On a router that lives at someone else's house
this removes a whole class of "it worked at home" problem, and it cleared a
`Tailscale can't reach the configured DNS servers` health warning on the test
device:

```sh
uci set network.wan.peerdns='0'
uci delete network.wan.dns
uci add_list network.wan.dns='1.1.1.1'
uci add_list network.wan.dns='8.8.8.8'
uci commit network
ifup wan
```

Verify with `grep nameserver /tmp/resolv.conf.d/resolv.conf.auto`.

---

## Related things worth checking

**Exit node not used at all.** Confirm the node is actually selected:

```sh
tailscale status | grep "exit node"          # should say "active; exit node"
tailscale debug prefs | grep ExitNodeID      # should be non-empty
curl -s https://api.ipify.org                # should be the exit node's IP
```

**LAN access while using an exit node.** If devices can reach the internet but
not each other, or you cannot reach the router, you want
`ExitNodeAllowLANAccess: true` (`tailscale up --exit-node-allow-lan-access ...`).

**DNS.** `tailscale status` may report *"Tailscale can't reach the configured DNS
servers"* when `CorpDNS` is false (MagicDNS off). Clients still resolve through
the router's dnsmasq, so browsing works — but DNS queries take your normal
resolvers rather than the tunnel. That is a privacy consideration, not a
connectivity fault.
