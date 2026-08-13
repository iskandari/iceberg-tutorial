#!/usr/bin/env bash
set -euo pipefail

YARN_URL="${YARN_URL:-http://localhost:8088}"
SPARK_UI_URL="${SPARK_UI_URL:-http://localhost:20888}"

command -v jq >/dev/null 2>&1 || {
  echo "jq is required. On macOS: brew install jq" >&2
  exit 1
}

apps="$(curl -fsS "$YARN_URL/ws/v1/cluster/apps?states=NEW,NEW_SAVING,SUBMITTED,ACCEPTED,RUNNING,FINISHED,FAILED,KILLED")"

printf '%s\n' "$apps" | jq -r --arg base "$SPARK_UI_URL" '
  (.apps.app // [])
  | sort_by(.startedTime)
  | reverse
  | .[]
  | [
      .id,
      .state,
      (.progress | tostring) + "%",
      (.allocatedVCores | tostring) + " vCPU",
      ((.allocatedMB / 1024 | floor) | tostring) + " GiB",
      $base + "/proxy/" + .id + "/"
    ]
  | @tsv
' | column -t -s $'\t'
