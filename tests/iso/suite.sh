#!/usr/bin/env bash

set -uo pipefail

usage() {
    echo "Usage: $0 ISO_PATH [OUTPUT_DIRECTORY]" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
    exit 2
fi

iso_path="$1"
output_directory="${2:-iso-test-output}"
smoke_output="$output_directory/smoke"
e2e_output="$output_directory/e2e"

mkdir -p "$output_directory"
status=0

if ! bash "$(dirname "$0")/iso-smoke-test.sh" "$iso_path" "$smoke_output"; then
    status=1
fi

if ! bash "$(dirname "$0")/iso-e2e-test.sh" "$iso_path" "$e2e_output"; then
    status=1
fi

exit "$status"
