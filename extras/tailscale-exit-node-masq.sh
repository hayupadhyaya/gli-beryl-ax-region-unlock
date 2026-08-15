#!/bin/sh
#
# Keep LAN clients working through a Tailscale exit node on GL.iNet firmware.
#
# THE PROBLEM
# GL.iNet's firmware creates a "tailscale0" firewall zone and wires up the
# lan <-> tailscale0 forwardings, but never enables masquerading on that zone.
# Forwarding without NAT means LAN client packets enter the tunnel still
# carrying their private 192.168.x.x source address. The exit node has no route
# back to that address, so every reply is dropped and clients see "no internet".
# The router itself is unaffected, because its own traffic already leaves with a
# valid 100.x.y.z Tailscale source - which is why the router has connectivity
# while everything behind it does not.
#
# THE FIX
# One line: masquerade traffic leaving the tailscale0 zone. This script applies
# it at both the config level (survives reboots) and the live iptables level (in
# case the chain was rebuilt), and is safe to run repeatedly.
#
# WHERE THIS RUNS FROM
#   /etc/firewall.user        - on every firewall reload (a preserved conffile,
#                               already registered as a firewall include)
#   /etc/firewall.tailscale.sh - whenever GL brings Tailscale up; /usr/bin/gl_tailscale
#                               runs this path if the file exists
#   cron                      - a periodic backstop
#
# SPDX-License-Identifier: MIT

CHAIN=zone_tailscale0_postrouting
ZONE=firewall.tailscale0

# --- config level: survives a reboot -----------------------------------------
# Only touch it if GL's tailscale zone actually exists. Do NOT reload the
# firewall from here - this script is itself run by the firewall reload.
if [ -n "$(uci -q get $ZONE.name)" ] && [ "$(uci -q get $ZONE.masq)" != "1" ]; then
    uci set $ZONE.masq='1'
    uci commit firewall
    logger -t ts-exit-masq "set $ZONE.masq=1 (was missing)"
fi

# --- live level: in case the chain was rebuilt without the rule --------------
if iptables -t nat -n -L "$CHAIN" >/dev/null 2>&1; then
    if ! iptables -t nat -C "$CHAIN" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A "$CHAIN" -j MASQUERADE
        logger -t ts-exit-masq "re-added MASQUERADE to $CHAIN"
    fi
fi

exit 0
