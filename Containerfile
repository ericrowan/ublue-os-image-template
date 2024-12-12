# Base Image
FROM ghcr.io/ublue-os/bluefin-dx:41

# --- Install RPM Fusion Repositories ---
RUN rpm-ostree install --apply-live \
    https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
    https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# --- Install build dependencies ---
RUN rpm-ostree install --apply-live \
    gcc make dkms kernel-headers kernel-devel elfutils-libelf-devel # Development tools and Parallels Tools dependency

# --- Copy Parallels Tools kmods folder ---
COPY parallels-tools /parallels-tools

# --- Install Parallels Tools ---
# Install dependencies for Parallels Tools
RUN rpm-ostree install --apply-live \
    xorg-x11-drv-fbdev \
    xorg-x11-drv-vesa

# Prepare /tmp/kmods folder
RUN mkdir -p /tmp/kmods && \
    cd /tmp/kmods && \
    tar -xvzf /parallels-tools/prl_mod.tar.gz

# Run the installer script and point to the /tmp/kmods folder
RUN /parallels-tools/install --install-component desktop --kmods-dir /tmp/kmods

# --- End Parallels Tools Installation ---

# Layer essential packages
RUN rpm-ostree install --apply-live \
    hyprland hyprland-protocols xdg-desktop-portal-hyprland \ # Hyprland and dependencies
    # Add other packages you need here

# --- Install VS Code (if not in base image) ---
# RUN rpm-ostree install --apply-live code # Or the appropriate package name

# --- Install Firefox (if not in base image) ---
# RUN rpm-ostree install --apply-live firefox # Or the appropriate package name

# --- Configure Hyprland (if necessary) ---
# Add any Hyprland configuration steps here

# --- Any Other Customizations ---
# Add any other customizations you need