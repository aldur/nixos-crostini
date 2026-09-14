# Sourced after user services are ready. Times come from systemd's
# monotonic clock, so polling latency is not counted as startup time.
echo "TIMING system manager"
systemctl show -p UserspaceTimestampMonotonic -p FinishTimestampMonotonic
for timing_unit in basic.target multi-user.target maitred.service vshd.service \
  systemd-user-sessions.service "user@$(id -u "$user").service" "${extra_system_units[@]}"; do
  echo "TIMING system $timing_unit"
  systemctl show "$timing_unit" -p InactiveExitTimestampMonotonic -p ActiveEnterTimestampMonotonic
done
for timing_unit in default.target garcon.service sommelier@0.service sommelier@1.service \
  sommelier-x@0.service sommelier-x@1.service; do
  echo "TIMING user $timing_unit"
  as_user systemctl --user show "$timing_unit" -p InactiveExitTimestampMonotonic -p ActiveEnterTimestampMonotonic
done
echo "TIMING end"
systemd-analyze critical-chain
systemd-analyze blame
