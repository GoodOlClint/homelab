#!/bin/sh
# keepalived track script: the VIP must follow a node whose PVE API actually
# answers, not just one that's powered on.
exec curl -ksf -o /dev/null --max-time 3 https://localhost:8006/
