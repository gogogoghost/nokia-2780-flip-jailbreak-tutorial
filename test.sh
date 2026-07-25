#!/bin/sh

set -e

test_download_base_url=${TEST_DOWNLOAD_BASE_URL:-}
test_compress_output=0
test_container_options="--privileged --network host"
output_dir=$(dirname "$PWD")

if [ -n "$test_download_base_url" ]; then
    act --container-options "$test_container_options" --artifact-server-path "$PWD/.artifacts" --env ACT_LOCAL_TEST=1 --env COMPRESS_OUTPUT="$test_compress_output" --env "DOWNLOAD_BASE_URL=$test_download_base_url" -W .github/workflows/release.yml -e .github/act-release-event.json push
else
    act --container-options "$test_container_options" --artifact-server-path "$PWD/.artifacts" --env ACT_LOCAL_TEST=1 --env COMPRESS_OUTPUT="$test_compress_output" -W .github/workflows/release.yml -e .github/act-release-event.json push
fi

artifact_zip=$(find "$PWD/.artifacts" -path '*/output/output.zip' -print -quit)

if [ -z "$artifact_zip" ]; then
    echo "Artifact zip not found" >&2
    exit 1
fi

mkdir -p "$output_dir"
rm -f "$output_dir/system-patched.img"
unzip -j -o "$artifact_zip" 'system-patched.img' -d "$output_dir"
