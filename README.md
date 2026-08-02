# Hyprland and Noctalia config files and tools

## Usage

```sh
git clone https://github.com/maddingo/hypr-config ~/.hypr-config
~/.hypr-config/install.sh
```

Symlinks `config-hypr` to `~/.config/hypr` and `config-noctalia` to `~/.config/noctalia`. An existing directory at either target is backed up as `<name>.backup-<timestamp>`.

If `noctalia` is not on `PATH`, it is built first — see `noctalia-install.md`.

| Variable | Default | Purpose |
|---|---|---|
| `NOCTALIA_SRC` | `~/Develop/noctalia` | Noctalia checkout to build in; cloned if absent, reused if present. |

