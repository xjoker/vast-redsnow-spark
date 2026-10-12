#!/bin/bash
# Start inference with the server layer in /root/vserver. Usage: vstart.sh [extra args...]
for p in $(pgrep -f "^/bin/bash /opt/redsnow/entrypoint.sh"); do kill $p; done
pkill -f "^python3 /(opt/redsnow|root/vserver)/server/serve_glm.py|^python3 /root/vserver/serve_glm.py"
while pgrep -f "^python3 /(opt/redsnow/server|root/vserver)/serve_glm.py" >/dev/null; do sleep 1; done
while ss -tan | grep -q ":8899 "; do sleep 2; done
set -a; . /root/redsnow.env; set +a
cd /root/vserver
setsid nohup python3 /root/vserver/serve_glm.py -m "$MODEL_DIR" -gs 112 --cache_size 262144 --cache_quant 4 --mtp --num_draft_tokens 2 --max-model-len 262144 --host 127.0.0.1 --port 8899 --served-model-name RED-SNOW-5.3-FLASH-EXL3-2.49 --request-timeout 7200 "$@" > /root/vserve.log 2>&1 < /dev/null &
