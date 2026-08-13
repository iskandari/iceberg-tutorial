#!/usr/bin/env bash
set -euo pipefail

mkdir -p /usr/lib/spark/jars
aws s3 cp \
  s3://ice.bird/tutorial/jars/sparklyr-3.5-2.12.jar \
  /usr/lib/spark/jars/sparklyr-3.5-2.12.jar
chmod 644 /usr/lib/spark/jars/sparklyr-3.5-2.12.jar

