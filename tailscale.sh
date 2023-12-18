#!/usr/bin/env bash

# make system configuration vars available
source /etc/os-release

# set invocation settings for this script:
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error when substituting.
# -o pipefail: the return value of a pipeline is the status of the last command to exit with a non-zero status, or zero if no command exited with a non-zero status
set -eu -o pipefail

# save the current directory silently
pushd . > /dev/null

# make a temporary directory, save the name, and move into it
dir="$(mktemp -d)"
cd "${dir}"

echo -n "Getting version..."

# get info for the latest version of Tailscale
tarball="$(curl -s 'https://pkgs.tailscale.com/stable/?mode=json' | jq -r .Tarballs.amd64)"
version="$(echo ${tarball} | cut -d_ -f2)"

echo "got ${version}."

echo -n "Downloading..."

# download the Tailscale package itself
curl -s "https://pkgs.tailscale.com/stable/${tarball}" -o tailscale.tgz

echo "done."

echo -n "Removing Legacy Installations..."

# Stop and disable the systemd service
if systemctl is-active --quiet tailscaled; then
  systemctl stop tailscaled
fi
if systemctl is-enabled --quiet tailscaled; then
  systemctl disable tailscaled
fi

# Remove the systemd system extension
if [ $(systemd-sysext list | grep -c "/var/lib/extensions/tailscale") -ne 0 ]; then
  systemd-sysext unmerge > /dev/null
  rm -rf /var/lib/extensions/tailscale
  systemd-sysext merge > /dev/null
fi

# Remove the overrides conf
if test -f /etc/systemd/system/tailscaled.service.d/override.conf; then
  rm -rf /etc/systemd/system/tailscaled.service.d/override.conf
fi

echo -n "Installing..."

# extract the tailscale binaries
tar xzf tailscale.tgz
tar_dir="$(echo ${tarball} | cut -d. -f1-3)"
test -d $tar_dir

# Create binaries directory in home
mkdir -p /opt/tailscale

# pull binaries
cp -rf $tar_dir/tailscale /opt/tailscale/tailscale
cp -rf $tar_dir/tailscaled /opt/tailscale/tailscaled

# add binaries to path via profile.d
if ! test -f /etc/profile.d/tailscale.sh; then
  mkdir -p /etc/profile.d/tailscale.sh
  echo 'PATH="$PATH:/home/deck/.bin"' >> /etc/profile.d/tailscale.sh
fi

# copy the systemd file into place
cp -rf $tar_dir/systemd/tailscaled.service /etc/systemd/system/tailscaled.service

# copy in the defaults file if it doesn't already exist
if ! test -f /etc/default/tailscaled; then
  cp -rf $tar_dir/systemd/tailscaled.defaults /etc/default/tailscaled
fi

# update paths in the unit file
sed -i 's@/usr/sbin/tailscaled@/opt/tailscale/tailscaled@g' /etc/systemd/system/tailscaled.service

# return to our original directory (silently) and clean up
popd > /dev/null
rm -rf "${dir}"

echo "Starting required services..."

# tailscaled - the tailscale daemon
# Note: enable and start/restart must be run because the legacy installation stops and disables
# any existing installations.
systemctl enable tailscaled
if systemctl is-active --quiet tailscaled; then
  echo "Upgrade complete. Restarting tailscaled..."
else
  echo "Install complete. Starting tailscaled..."
fi
systemctl restart tailscaled # This needs to be the last thing we do in case the user's running this over Tailscale SSH.

echo "Done."
