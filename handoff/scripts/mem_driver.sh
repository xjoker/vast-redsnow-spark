#!/bin/bash
# Run A / A2 / B in turn. Record memory.events before and after each; probe liveness after each and stop if the service is down.
RES=/root/mem_results.jsonl
EV=/root/mem_events.log
: > $RES
: > $EV
ev() { echo "$(date +%T) $1 | $(cat /sys/fs/cgroup/memory.events | tr '\n' ' ')" >> $EV; }
alive() { [ "$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://127.0.0.1:8899/v1/models)" != "000" ]; }
for t in A A2 B; do
  ev "before $t"
  python3 /root/mem_test.py $t >> $RES 2>> /root/mem_test.err
  ev "after $t"
  if ! alive; then echo "$(date +%T) SERVER DOWN after $t" >> $EV; break; fi
done
echo "$(date +%T) DRIVER DONE" >> $EV
