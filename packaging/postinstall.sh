#!/bin/sh
udevadm control --reload-rules >/dev/null 2>&1 || true
udevadm trigger --subsystem-match=misc --sysname-match=uinput >/dev/null 2>&1 || true
