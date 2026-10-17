# Stream Wavelog's application log to stdout so it reaches `kubectl logs`.
#
# CodeIgniter writes one file per UTC day, application/logs/log-YYYY-MM-DD.php
# (Wavelog pins date_default_timezone_set to UTC). Follow today's file from
# its start, switch at UTC midnight, and drop files older than a day so the
# emptyDir stays small. `tail -F` waits for a file that doesn't exist yet.
set -u
cd /var/www/html/application/logs || { echo "log-tail: application/logs missing" >&2; exit 1; }
tailpid=""
trap '[ -n "$tailpid" ] && kill "$tailpid" 2>/dev/null; exit 0' TERM INT
while :; do
  today="log-$(date -u +%F).php"
  find . -maxdepth 1 -name 'log-*.php' ! -name "$today" -mmin +1440 -delete 2>/dev/null
  tail -n +1 -F "$today" 2>/dev/null &
  tailpid=$!
  # Sleep (in the background, so the TERM trap runs) until just past midnight.
  sleep $((86400 - $(date -u +%s) % 86400 + 5)) &
  wait $!
  kill "$tailpid" 2>/dev/null
  wait "$tailpid" 2>/dev/null
done
