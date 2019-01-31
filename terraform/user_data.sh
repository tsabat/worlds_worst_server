#!/bin/bash -ex

# pass the port in as first arg, or get port 8000
port=${1:-8000}

# pass something you want to see the index say
message=${2-'default message'}


# if we're on linux
if which lsb_relase; then
  # log to stdout and user-data.log
  exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
fi

# create a folder for this
server_home="$HOME/simpleserver"
# cd into it
cd "$server_home" || mkdir "$server_home" && cd "$server_home"
echo "$message" > index.html


python -m SimpleHTTPServer "$port"
