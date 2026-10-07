# Dual-boot path: a second Linux install dedicated to omp

Use this only if you need bare-metal GPU/driver access or want full isolation from the daily OS.
For everything else the VM (`../vm`) or container (`../container`) is cheaper and reversible.

## Layout

```
disk
├─ EFI System Partition (existing, shared)      ~512 MB  FAT32
├─ OS A: existing daily system                   (untouched)
├─ OS B: omp Linux root                          ≥ 40 GB ext4   ← new
└─ shared data: /srv/code (projects)             any size ext4  ← new, mounted by both OSes
```

Rules that keep this safe:

1. **Never shrink a mounted partition.** Resize OS A from a live USB (`gparted`), or use free space.
2. **One ESP.** Install OS B's bootloader into the existing ESP; do not create a second one.
3. **Shared data partition, not a shared home.** `~/.omp` must stay per-OS: `agent.db`
   (credentials), `sessions/`, `stats.db`, and `~/.omp/run/*.sock` are not safe to share.
4. **No Windows fast-startup / hibernation** if OS A is Windows, otherwise NTFS mounts are read-only or corrupt.

## Steps

### 1. Carve space (from a live USB)

```sh
sudo gparted            # shrink OS A, leave ≥ 40 GB + shared data unallocated
```

### 2. Install OS B (Ubuntu 24.04 example)

Installer → "Something else" / manual partitioning:

| Mount point | Size   | FS   | Note                            |
| ----------- | ------ | ---- | ------------------------------- |
| `/boot/efi` | reuse  | FAT  | select the EXISTING ESP, flag `esp`, do **not** format |
| `/`         | ≥40 GB | ext4 | OS B root                       |
| `/srv/code` | rest   | ext4 | shared projects (optional)      |

Install the bootloader to the disk that holds the ESP. GRUB's `os-prober` picks up OS A; if the entry is missing after reboot:

```sh
sudo sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
sudo update-grub
```

### 3. First boot of OS B: install omp

```sh
sudo apt update && sudo apt install -y curl git ca-certificates python3 python3-venv build-essential
curl -fsSL https://omp.sh/install | sh          # prebuilt binary → ~/.local/bin/omp
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && exec bash
omp --version
omp setup python --check                         # optional features: python | speech
omp login                                        # OAuth / API key → ~/.omp/agent/agent.db
eval "$(omp completions bash)"                   # add to ~/.bashrc
```

### 4. Share projects, not state

```sh
# /etc/fstab on BOTH OSes (UUID from: lsblk -f)
UUID=<shared-uuid>  /srv/code  ext4  defaults,noatime  0 2
```

Then in OS B: `omp --cwd /srv/code/<project>`. Each project keeps its own `<project>/.omp/`
(rules, project config), which is fine to share; the per-user `~/.omp` stays local to each OS.

### 5. Make the host omp and the omp-OS talk (optional)

Dual-boot is exclusive — only one OS runs at a time — so there is no live link like the VM
broker. Two workable patterns:

- **Shared `.env` per project**: `/srv/code/<project>/.env` with a provider key is read by whichever
  OS is booted (`<project>/.env` outranks `~/.omp/agent/.env`; see `omp://environment-variables.md`).
- **Session export/import**: `omp --export <session-id>` to HTML on one side for reading; or point
  both OSes at the same `--session-dir /srv/code/.omp-sessions` to resume the same transcripts
  (sessions are JSONL; credentials are not in them).

## Rollback

Boot OS A, delete the OS B and `/srv/code` partitions with `gparted`, then remove OS B's loader:

```sh
sudo efibootmgr                                  # find the OS B entry
sudo efibootmgr -b <NNNN> -B
sudo rm -rf /boot/efi/EFI/ubuntu                 # the OS B directory in the ESP
```
