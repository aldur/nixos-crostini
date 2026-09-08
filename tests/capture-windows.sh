# Run beside crosvm, with XDG_RUNTIME_DIR and WAYLAND_DISPLAY set by the test.
# The probe opens the windows in the order below, each titled after the
# variable that gave its display. Each capture also reports the size of
# the window on the host, and the ratio between the low-density instance
# at scale 0.5 and the one at scale 1.0: an application on the first sees
# a screen with half the pixels, so its window takes twice the size.
set -euo pipefail

# The size of a window in the scene graph of Weston: the line after its
# view gives the corners.
window_size() {
  awk -v title="$1" '
    index($0, title) { found = 1; next }
    found && /position:/ {
      gsub(/[(),>-]/, " ")
      print $4 - $2 "x" $5 - $3
      exit
    }
  ' "$2"
}

# The ratio of two sizes, when one is the exact double of the other.
scale() {
  local w0=${1%x*} h0=${1#*x} w1=${2%x*} h1=${2#*x}
  if [ "$w0" = $((2 * w1)) ] && [ "$h0" = $((2 * h1)) ]; then
    echo 2x2
  else
    echo "$1/$2"
  fi
}

declare -A size
for slug in gtk2-normal gtk2-low gtk3-normal gtk3-low; do
  # The closing quote of the title keeps `DISPLAY` apart from
  # `DISPLAY_LOW_DENSITY` in the scene graph.
  case $slug in
    gtk2-normal) title="Baguette GTK2 DISPLAY'" ;;
    gtk2-low) title="Baguette GTK2 DISPLAY_LOW_DENSITY'" ;;
    gtk3-normal) title="Baguette GTK3 WAYLAND_DISPLAY'" ;;
    gtk3-low) title="Baguette GTK3 WAYLAND_DISPLAY_LOW_DENSITY'" ;;
  esac
  directory="screenshots/$slug"
  mkdir -p "$directory"
  # Check the host's scene graph as well: X11 mapping alone does not prove
  # that Sommelier has submitted the window to the host compositor.
  # crosvm buffers serial output, so probe.log cannot signal readiness live.
  echo "Waiting for $title in Weston"
  while true; do
    weston-debug scene-graph > "$directory/scene.log"
    if grep -q "$title" "$directory/scene.log"; then
      break
    fi
    sleep 0.1
  done
  # Let the first widget paints reach the compositor before its capture.
  sleep 1
  (cd "$directory" && weston-screenshooter)
  mv "$directory"/wayland-screenshot-*.png "screenshots/$slug.png"
  size[$slug]=$(window_size "$title" "$directory/scene.log")
  echo "Captured $title"
  echo "PROBE host-window $slug ${size[$slug]}"
  case $slug in
    *-low)
      toolkit=${slug%-low}
      echo "PROBE host-scale $toolkit $(scale "${size[$slug]}" "${size[$toolkit-normal]}")"
      ;;
  esac
done
