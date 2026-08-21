#!/bin/sh
# keepalived track script: the VIP must follow an instance whose resolver
# answers the given name on :53, not one that is merely up. A locally-served
# name keeps upstream outages from flapping the VIP between two equally-affected
# instances. dig exits 0 on SERVFAIL, so require a non-empty answer.
[ -n "$(dig +short +time=1 +tries=1 @127.0.0.1 "$1")" ]
