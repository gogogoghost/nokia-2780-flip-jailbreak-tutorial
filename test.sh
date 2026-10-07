#!/bin/sh

set -e

# Load local configuration if present (see .env.example and contributor.md).
if [ -f "$PWD/.env.local" ]; then
    # shellcheck disable=SC1091
    . "$PWD/.env.local"
fi

test_compress_output=0
test_container_options="--privileged --network host"
output_dir=$(dirname "$PWD")

# Act env vars: pass through the settings used by the workflow.
act_env_args="--env ACT_LOCAL_TEST=1 --env COMPRESS_OUTPUT=$test_compress_output"

# Mount a local mirror of the build files so no network download is needed.
if [ -n "${LOCAL_SOURCE_DIR:-}" ]; then
    if [ ! -d "$LOCAL_SOURCE_DIR" ]; then
        echo "LOCAL_SOURCE_DIR not found: $LOCAL_SOURCE_DIR" >&2
        echo "Set it in .env.local or point it at a directory with emmc.img.xz, init, su, appscmd, ostore.zip" >&2
        exit 1
    fi
    test_container_options="$test_container_options -v $LOCAL_SOURCE_DIR:/local-src:ro"
    act_env_args="$act_env_args --env LOCAL_SOURCE_DIR=/local-src"
elif [ -n "${TEST_DOWNLOAD_BASE_URL:-}" ]; then
    act_env_args="$act_env_args --env DOWNLOAD_BASE_URL=$TEST_DOWNLOAD_BASE_URL"
fi

# shellcheck disable=SC2086
act --container-options "$test_container_options" --artifact-server-path "$PWD/.artifacts" $act_env_args -W .github/workflows/release.yml -e .github/act-release-event.json push

artifact_zip=$(find "$PWD/.artifacts" -path '*/output/output.zip' -print -quit)

if [ -z "$artifact_zip" ]; then
    echo "Artifact zip not found" >&2
    exit 1
fi

mkdir -p "$output_dir"
rm -f "$output_dir/system-patched.img"
unzip -j -o "$artifact_zip" 'system-patched.img' 'dtbo.img' -d "$output_dir"
