# rom-link

Builds symlink-based ROM directory structures for multiple target OS layouts
(Batocera, EmuDeck, RetroPie, etc.) without duplicating any data.

Your canonical ROM collection stays untouched. Each OS gets its own folder tree
of symlinks shaped to its exact expectations, served over NFS.

---

## File Structure

```
rom-link.sh           # Main script
configs/
  batocera.conf       # Config for Batocera Linux
  emudeck.conf        # Config for EmuDeck
  retropie.conf       # (add your own)
```

---

## Usage

```bash
# Basic run against one OS config
./rom-link.sh configs/batocera.conf

# Dry run — preview all actions, nothing is changed
./rom-link.sh --dry-run configs/batocera.conf

# Run with logging
./rom-link.sh --log /var/log/rom-link.log configs/batocera.conf

# Verbose output (shows every file, not just system summaries)
./rom-link.sh --verbose configs/batocera.conf

# Run multiple OS configs in one pass
./rom-link.sh --log /var/log/rom-link.log configs/batocera.conf configs/emudeck.conf

# Combine flags
./rom-link.sh --dry-run --verbose configs/batocera.conf
```

---

## Config File Format

```ini
# Required global settings
os_name        = Batocera
canonical_root = /mnt/pool/roms       # Your master ROM collection
target_root    = /mnt/pool/batocera-roms  # Where symlink tree is built

[systems]
# dest_folder = source/relative/path : mode

nes        = nintendo/nes   : flat
psx        = sony/psx       : recursive
mame       = arcade/mame    : dir
```

### Modes

| Mode        | Behavior | Use For |
|-------------|----------|---------|
| `flat`      | Links files at the top level of the system folder only | Cartridge systems — NES, SNES, GBA, etc. |
| `recursive` | Mirrors full subdirectory tree with file-level links | Disc-based systems — PSX, PS2, Dreamcast, etc. |
| `dir`       | Creates a single directory-level symlink | MAME/arcade sets where internal structure is self-managed |

---

## NFS Setup (TrueNAS Scale)

Export the **common parent** of both your canonical root and target roots so
NFS resolves symlinks server-side. Clients see plain folders and files — they
never know symlinks are involved.

**TrueNAS UI:** Shares → Unix (NFS) Shares → Add
- Path: `/mnt/pool` (parent of both `roms/` and `batocera-roms/`)
- Enable **"All dirs"** so clients can mount subdirectories

**Client mount example:**
```bash
mount -t nfs truenas-ip:/mnt/pool/batocera-roms /userdata/roms
```

---

## Automating with Cron (TrueNAS Scale)

Schedule nightly syncs under **System → Advanced → Cron Jobs**:

```
0 2 * * * /mnt/pool/scripts/rom-link.sh --log /var/log/rom-link.log /mnt/pool/scripts/configs/batocera.conf /mnt/pool/scripts/configs/emudeck.conf
```

---

## Behavior Details

- **OS-managed files** (like Batocera's `_info.txt`) are never overwritten — the
  script detects real files and skips them
- **Existing correct symlinks** are skipped (no unnecessary I/O)
- **Stale symlinks** (pointing to wrong target) are updated automatically
- **Missing source directories** produce a warning and are skipped gracefully
- **Exit code 1** is returned if any errors occurred, suitable for cron alerting
