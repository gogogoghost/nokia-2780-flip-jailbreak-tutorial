#!/bin/sh

set -e

act --container-options "--privileged -v /dev:/dev" --artifact-server-path $PWD/.artifacts push
