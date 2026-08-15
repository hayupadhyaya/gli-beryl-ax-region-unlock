# Which country codes can I use?

This is really two questions with two different answers, because the region code
and the Wi-Fi regulatory domain are separate settings with separate rules.

---

## 1. The region code (what unhides the VPN pages)

**Any two-letter uppercase code that is not `CN`.** There is no approved list,
because there is no list to be on — the firmware only ever asks "is this CN?":

```js
// /www/js/app.*.js  - the menu filter
countryCode.toLowerCase().indexOf("cn") >= 0 && lang_hide.includes("zh-cn")
```

```sh
# /etc/init.d/mptun
[ "$(get_country_code)" = "CN" ] && { ...disable the tunnel datapath... }
```

`CA`, `US`, `DE`, `GB` and `JP` all behave identically here. So does any other
non-`CN` value.

Two things to know:

- The UI test is a **substring** match on `cn`, not equality. `CN` is the only
  real ISO 3166-1 code containing those two letters, so in practice this only
  matters if you invent a code.
- The `mptun` test *is* an exact equality against `CN`.

`glinet-region.sh` requires two uppercase letters (`[A-Z][A-Z]`) and nothing
else. That is a deliberate guard against typos writing junk into flash, not a
firmware requirement.

**Pick the code for where the router physically is**, because the same value is
the sensible one for the Wi-Fi domain below, and that one is a legal question
rather than a cosmetic one.

---

## 2. The Wi-Fi regulatory domain (what governs channels and power)

This one **does** have a list. It comes from the kernel's wireless regulatory
database at `/lib/firmware/regulatory.db`, and a code that is not in it will not
give you a valid domain.

The reference device (GL-MT3000, firmware 4.8.1, regdb version 20) ships **166**
codes:

```
AD AE AF AI AL AM AR AS AT AU AW AZ BA BB BD BE BF BG BH BL
BM BN BO BR BS BT BY BZ CA CF CH CI CL CN CO CR CU CY CZ DE
DK DM DO DZ EC EE EG ES ET FI FM FR GB GD GE GF GH GL GP GR
GT GU GY HK HN HR HT HU ID IL IN IR IS IT JM JO JP KE KH KN
KP KR KY KZ LB LC LI LK LS LT LU LV MA MC MD ME MF MH MK MN
MO MP MQ MR MT MU MV MW MX MY NG NI NL NO NP NZ OM PA PE PF
PG PH PK PL PM PR PT PW PY QA RO RS RU RW SA SE SG SK SN SR
SS SV SY TC TD TG TH TN TR TW TZ UA US UY UZ VC VE VI VN VU
WF WS YE YT ZA ZW
```

It also contains `00`, the "world" domain — the deliberately conservative
fallback used when no country is known.

Note there is no country **picker** for this in the GL admin panel on this model,
which is why it has to be set through `uci` (or `glinet-region.sh wifi`).

### Reading the list off your own device

Firmware versions ship different regdb revisions, so confirm against yours rather
than trusting the list above. Copy the database to a computer:

```sh
scp -O root@192.168.8.1:/lib/firmware/regulatory.db .
```

then extract the codes it actually contains:

```sh
python3 - regulatory.db <<'PY'
import re, sys
data = open(sys.argv[1], 'rb').read()
iso = set(open('/usr/share/zoneinfo/iso3166.tab').read().split()) if False else None
found = sorted({m.group().decode() for m in re.finditer(rb'[A-Z][A-Z]', data)})
print(len(found), "candidates:", " ".join(found))
PY
```

Cross-check the output against ISO 3166-1 alpha-2 — the raw scan picks up a few
false positives from adjacent binary data, so treat anything that is not a real
country code as noise.

### Setting it

```sh
/tmp/glinet-region.sh wifi CA
```

See [the Wi-Fi step in the README](../README.md#5-wi-fi-regulatory-domain--do-not-skip-this)
— it reloads the radios, so it disconnects Wi-Fi clients and arms an automatic
rollback in case the new domain leaves you unable to reconnect.

---

## Which should you actually pick?

The one matching where the router physically operates. The regulatory domain
decides which channels are legal and at what transmit power, and getting it wrong
means transmitting outside your local rules — a real constraint, not a formality.

If the router travels, set it for wherever it is spending its time rather than
where it was bought. Leaving a Chinese-market unit on `CN` while it sits in North
America is exactly the mismatch worth fixing, and it is the reason the `wifi` step
exists separately from the region patch at all.
