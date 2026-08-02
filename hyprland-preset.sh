# Preset for LinuxBeginnings/Ubuntu-Hyprland `install.sh --preset`.
# Sourced by that script, so only Y/N values — anything else makes it fail.
#
# The point of this file is dots="N": this repo supplies its own config, and
# upstream's installer has no flag for skipping the KooL dotfiles, only a
# whiptail prompt. Everything else follows upstream's own preset.sh.

###-Would you like script to Configure NVIDIA for you?
nvidia="N"

###-Install GTK themes (required for Dark/Light function)?
gtk_themes="Y"

###-Do you want to configure Bluetooth?
bluetooth="Y"

###-Do you want to install Thunar file manager?
thunar="Y"
### Do you want to set Thunar as the default file manager?
thunar_choice="Y"

### Adding user to the 'input' group might be necessary for waybar keyboard-state functionality
input_group="Y"

### Install AGS (aylur's GTK shell) v1 for Desktop-Like Overview?
ags="N"

###-Install & configure SDDM log-in Manager
sddm="Y"
### install and download SDDM themes
sddm_theme="Y"

###-Install XDG-DESKTOP-PORTAL-HYPRLAND? (For proper Screen Share ie OBS)
xdph="Y"

###-Install zsh, oh-my-zsh
zsh="Y"

### add Pokemon color scripts to terminal
pokemon_choice="N"

### Install nwg-look? (a GTK Theming app - lxappearance-like)
nwg="Y"

###-Installing on Asus ROG Laptops?
rog="N"

###-Do you want to add pre-configured KooL's Hyprland dotfiles?
dots="N"
