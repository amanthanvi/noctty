#!/bin/bash
# Summarize a hunt run: summarize_fixhunt.sh <run id> <out dir>
cd /c/Users/amant/.t3/worktrees/winghostty/wt-harn-scratch || exit 1
run=$1
dir=$2
mkdir -p "$dir"
for id in $(gh api repos/amanthanvi/noctty/actions/runs/$run/jobs --jq '.jobs[].id'); do
  name=$(gh api repos/amanthanvi/noctty/actions/jobs/$id --jq .name)
  gh api --allow-escape-sequences repos/amanthanvi/noctty/actions/jobs/$id/logs 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$dir/$id.log"
  cpu=$(grep -a -m1 -o 'cpu: [A-Za-z0-9]* [A-Za-z0-9]* [0-9A-Za-z]*' "$dir/$id.log")
  runs=$(grep -a -E 'RUN [0-9] exit=' "$dir/$id.log" | sed 's/^[0-9T:.Z-]* RUN //; s/ exit=/:/; s/ seconds=/ /' | paste -sd' ')
  echo "== $name: $cpu | $runs"
done
echo "retries absorbed:"
grep -a -h "console dump retried" "$dir"/*.log | sed 's/^[0-9T:.Z-]* //' | cut -c1-110 | sort | uniq -c | sort -rn | head
echo "totals:"
cat "$dir"/*.log | grep -a -E "RUN [0-9] exit=" | sed 's/^[0-9T:.Z-]* //' | awk '{n++; if ($3!="exit=0") h++} END {print n " runs, " h+0 " not exit 0"}'
