# Hyprland and Noctalia config files and tools

## Usage

```sh
git clone https://github.com/maddingo/hypr-config ~/.hypr-config
~/.hypr-config/install.sh
```

Symlinks `config-hypr` to `~/.config/hypr` and `config-noctalia` to `~/.config/noctalia`. An existing directory at either target is backed up as `<name>.backup-<timestamp>`.

If `Hyprland` is not on `PATH` and this is an Ubuntu 24.04 base, it is installed
first via [Ubuntu-Hyprland](https://github.com/LinuxBeginnings/Ubuntu-Hyprland),
driven by `hyprland-preset.sh` so its own dotfiles are skipped in favour of this
repo's. That step needs sudo and still asks a few questions.

If `noctalia` is not on `PATH`, it is built next — see `noctalia-install.md`.

| Variable | Default | Purpose |
|---|---|---|
| `HYPRLAND_SRC` | `~/Develop/Ubuntu-Hyprland` | Ubuntu-Hyprland checkout; cloned if absent, reused if present. |
| `NOCTALIA_SRC` | `~/Develop/noctalia` | Noctalia checkout to build in; cloned if absent, reused if present. |

