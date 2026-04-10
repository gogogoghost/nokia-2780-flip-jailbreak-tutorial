#!/bin/sh

set -e

test_download_base_url=${TEST_DOWNLOAD_BASE_URL:-}
test_compress_output=0
test_container_options="--device /dev/fuse --cap-add SYS_ADMIN --security-opt label=disable --network host"
output_dir=$(dirname "$PWD")

act_args="--container-options $test_container_options --artifact-server-path $PWD/.artifacts --env ACT_LOCAL_TEST=1 --env COMPRESS_OUTPUT=$test_compress_output -W .github/workflows/release.yml -e .github/act-release-event.json push"

if [ -n "$test_download_base_url" ]; then
  act_args="$act_args --env DOWNLOAD_BASE_URL=$test_download_base_url"
fi

eval "act $act_args"

artifact_zip=$(find "$PWD/.artifacts" -path '*/output/output.zip' -print -quit)

if [ -z "$artifact_zip" ]; then
    echo "Artifact zip not found" >&2
    exit 1
fi

mkdir -p "$output_dir"
rm -f "$output_dir/system-patched.img"
unzip -j -o "$artifact_zip" 'system-patched.img' -d "$output_dir"
