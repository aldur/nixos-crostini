# Run beside crosvm, with XDG_RUNTIME_DIR and WAYLAND_DISPLAY set by the test.
set -euo pipefail

for display in 0 1; do
  directory="screenshots/gtk2-$display"
  mkdir -p "$directory"
  # Check the host's scene graph as well: X11 mapping alone does not prove
  # that Sommelier has submitted the window to the host compositor.
  # crosvm buffers serial output, so probe.log cannot signal readiness live.
  echo "Waiting for Baguette GTK2 :$display in Weston"
  while true; do
    weston-debug scene-graph > "$directory/scene.log"
    if grep -q "Baguette GTK2 :$display" "$directory/scene.log"; then
      break
    fi
    sleep 0.1
  done
  # Let the first widget paints reach the compositor before its capture.
  sleep 1
  (cd "$directory" && weston-screenshooter)
  mv "$directory"/wayland-screenshot-*.png "screenshots/gtk2-$display.png"
  echo "Captured Baguette GTK2 :$display"
done
