# Derived from sommelier.sh from https://chromium.googlesource.com/chromiumos/containers/cros-container-guest-tools
# Original source: Copyright 2019 The ChromiumOS Authors

# Not running under sommelier?
if ! systemctl --user show-environment | grep -q '^SOMMELIER_VERSION='; then
  return 0
fi

# Helper function to export a variable if it isn't already set
__sommelier_export() {
  local var="$1"
  # We have to resort to eval as POSIX doesn't support ${!var} indirection.
  if [ -n "$(eval "[ -z \"\${$var}\" ] || echo unset")" ]; then
    local setting
    # Only export the var if it's been defined.  This might be an account that
    # the user has setup or modified.  No point in spewing errors.
    if setting="$(systemctl --user show-environment | grep "^${var}=")"; then
      export "${setting}"
    fi
  fi
}

__sommelier_export DISPLAY
__sommelier_export DISPLAY_LOW_DENSITY
__sommelier_export XCURSOR_SIZE
__sommelier_export XCURSOR_SIZE_LOW_DENSITY
__sommelier_export WAYLAND_DISPLAY
__sommelier_export WAYLAND_DISPLAY_LOW_DENSITY

# No need to export this to the shell env.
unset -f __sommelier_export
