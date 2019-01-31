#!/bin/bash -ex

# if we're on linux
if which lsb_relase; then
  exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
fi

python -m SimpleHTTPServer 8000