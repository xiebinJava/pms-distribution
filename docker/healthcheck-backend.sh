#!/bin/sh
set -eu
response="$(curl --fail --silent --show-error --max-time 4 http://127.0.0.1:8080/api/health/ready)"
case "$response" in
  *'"status":"UP"'*) exit 0 ;;
  *) exit 1 ;;
esac

