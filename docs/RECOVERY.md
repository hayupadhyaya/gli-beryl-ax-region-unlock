# Recovery

Work down this page in order. Stop as soon as the router is healthy again.
Most failures are recoverable; the one that is not is losing your Factory
partition backup, so if you still have a shell, **get the backup off the router
before you do anything else.**

---

## First: which failure is it?

| Symptom | Where to go |
|---|---|
| Script printed "MORE BYTES CHANGED THAN EXPECTED" | [1. Restore from backup](#1-restore-from-backup) |
| Patch reported success but `/proc` still shows the old code | [2. Code did not take](#2-code-did-not-take) |
| Router boots, but Wi-Fi is gone or radios do not come up | [1. Restore from backup](#1-restore-from-backup) |
| Router boots, VPN section still hidden | [3. Region changed but UI still locked](#3-region-changed-but-ui-still-locked) |
| Router does not boot / no LAN / no admin panel | [4. U-Boot recovery](#4-u-boot-recovery) |
| Radios dead **and** you have no backup | [5. No backup](#5-no-backup) |
| Wi-Fi did not come back after `wifi <CC>` | [6. Wi-Fi lockout](#6-wi-fi-lockout) |

---

## 1. Restore from backup

If you still have a shell, this is the direct undo. It writes your pre-change
image back over the Factory partition.

```sh
# ON YOUR COMPUTER - push the backup and the script back to the router.
# /tmp is a ramdisk, so both are gone after any reboot.
scp -O ~/glinet-factory-backup.bin root@192.168.8.1:/tmp/factory_backup.bin
scp -O glinet-region.sh root@192.168.8.1:/tmp/

# ON THE ROUTER
ssh root@192.168.8.1
chmod +x /tmp/glinet-region.sh
/tmp/glinet-region.sh restore /tmp/factory_backup.bin
reboot
```

If you also saved a copy to the router's own flash (`/root/factory_backup.bin`),
skip the upload and restore straight from there.

The script refuses to restore an image whose size does not match the partition,
which catches the common mistake of restoring a truncated or wrong-model dump.

Manual equivalent, if the script will not run:

```sh
cat /proc/mtd                                    # find the Factory partition
dd if=/tmp/factory_backup.bin of=/dev/mtdblock3 bs=4096   # use YOUR number
sync
reboot
```

After rebooting, confirm the damage is undone:

```sh
cat /proc/gl-hw-info/device_mac      # should be your original MAC
iwinfo                               # radios should enumerate
```

---

## 2. Code did not take

`/proc/gl-hw-info/country_code` is read by a kernel module at boot. It does not
re-read the partition while running, so a patch will not show up until you
reboot.

```sh
reboot
# then
cat /proc/gl-hw-info/country_code
```

If it is still the old value after a reboot, check what is actually in flash:

```sh
/tmp/glinet-region.sh status
```

If `country code (flash)` shows your new code but `/proc` does not, your model
reads the code from somewhere other than offset `0x88` of the Factory partition.
Do not go hunting by writing more bytes. Use the `soft` method instead — it
overrides the value regardless of where it is stored.

---

## 3. Region changed but UI still locked

Check the three layers in order:

```sh
cat /proc/gl-hw-info/country_code                        # kernel view
. /lib/functions/gl_util.sh; get_country_code            # firmware view
uci -q get board_special.hardware.country_code           # override, if any
```

- All three showing a non-`CN` value? Hard-refresh the admin panel
  (Cmd/Ctrl+Shift+R) and log out and back in. The panel caches its feature list.
- Still hidden? Reboot once more — some GL services only evaluate the region at
  startup.
- Still hidden after that? Apply the override as well; `soft` and `patch` are
  complementary and can both be in place at once:

```sh
/tmp/glinet-region.sh soft CA
```

---

## 4. U-Boot recovery

Use this when the router will not boot or you cannot reach it at all. This
reinstalls firmware. It does **not** repair the Factory partition — if your
calibration data is damaged, reflashing will not bring the radios back, so read
[section 5](#5-no-backup) too.

1. Unplug power.
2. Hold the **reset** button.
3. Plug power back in, keep holding.
4. Watch the LED. On the GL-MT3000 the blue LED flashes **6 times**, then goes
   solid white — that means U-Boot failsafe is up. Release reset.
5. Set your computer's Ethernet interface to a **static** address:
   - IP `192.168.1.2`, mask `255.255.255.0`
6. Open <http://192.168.1.1> and upload a firmware image.

Get images from <https://dl.gl-inet.com/> — pick your exact model. If the CN
firmware is what you have, the global image is fine to flash; it will still read
whatever region code is in the Factory partition.

Official documentation: <https://docs.gl-inet.com/router/en/4/faq/debrick/>

---

## 5. No backup

If the Factory partition is damaged and you have no backup, be realistic about
what is recoverable:

- **MAC addresses** can be overridden in software. It is a workaround, not a fix,
  but it gets the device usable:
  ```sh
  uci set network.lan.macaddr='94:83:c4:xx:xx:xx'
  uci commit network && /etc/init.d/network restart
  ```
  Use the MAC printed on the label on the underside of the router.

- **RF calibration data** cannot be reconstructed. It is unique per unit and is
  not contained in any firmware image. If it is gone, the radios will either not
  come up or will perform badly, and no reflash will change that.

- **Another unit's dump will not work.** It carries that unit's MACs, serials and
  calibration. Flashing it gives you duplicate MACs on your network and wrong
  calibration for your radio. Do not do this.

At that point the honest options are GL.iNet support (expect the warranty
conversation) or using the device over Ethernet only.

---

## 6. Wi-Fi lockout

`wifi <CC>` reloads the radios. If you ran it over a Wi-Fi connection and the
network did not come back, **wait two minutes before doing anything else.**

The command arms a detached rollback watcher before it applies the change. If it
is not confirmed within 120 seconds, it restores the previous country values and
reloads the radios again. In most cases the network returns on its own and you
have lost nothing.

If it is still down after three minutes:

1. **Plug in Ethernet** to a LAN port and reach the router at `192.168.8.1`. The
   wired path is unaffected by any regulatory-domain setting.
2. Put the old value back:
   ```sh
   /tmp/glinet-region.sh wifi CN --now
   ```
   `--now` skips the rollback machinery, which is what you want on a cable.
3. If the script is gone (`/tmp` is wiped by reboots), do it by hand:
   ```sh
   uci show wireless | grep country
   uci set wireless.<radio>.country='CN'    # for each radio
   uci commit wireless && wifi reload
   ```

If Wi-Fi still does not come up on a domain you know is valid, the radios may
have been configured onto a channel that domain forbids. Force a legal one:

```sh
uci set wireless.<2g radio>.channel='6'
uci set wireless.<5g radio>.channel='36'
uci commit wireless && wifi reload
```

`channel='auto'` is the safest setting, because the driver then picks a channel
that is legal for whatever domain is configured.

---

## Getting help

When asking anywhere public, include:

```sh
cat /etc/glversion
cat /proc/mtd
cat /proc/gl-hw-info/country_code
/tmp/glinet-region.sh status
```

Redact your MAC addresses and serial numbers from `status` output before posting
it — they are unique identifiers for your device.
