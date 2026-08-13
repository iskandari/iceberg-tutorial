#!/usr/bin/env python3
"""Execute every code cell in the tutorial notebook through local Livy."""

import json
import time
import urllib.request
from pathlib import Path

LIVY = "http://localhost:8998"
NOTEBOOK = Path(__file__).parents[1] / "examples" / "vpts_iceberg_tutorial.ipynb"


def request(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        LIVY + path,
        data=data,
        method=method,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=300) as response:
        return json.load(response)


session = request(
    "POST",
    "/sessions",
    {
        "kind": "pyspark",
        "conf": {
            "spark.dynamicAllocation.initialExecutors": "1",
            "spark.dynamicAllocation.maxExecutors": "12",
        },
    },
)
session_id = session["id"]

try:
    while request("GET", f"/sessions/{session_id}/state")["state"] not in {"idle"}:
        state = request("GET", f"/sessions/{session_id}/state")["state"]
        if state in {"dead", "error", "killed", "shutting_down"}:
            raise RuntimeError(f"Livy session entered {state}")
        time.sleep(3)

    notebook = json.loads(NOTEBOOK.read_text())
    cells = [cell for cell in notebook["cells"] if cell["cell_type"] == "code"]
    for number, cell in enumerate(cells, start=1):
        statement = request(
            "POST",
            f"/sessions/{session_id}/statements",
            {"code": "".join(cell["source"])},
        )
        statement_id = statement["id"]
        while True:
            result = request(
                "GET", f"/sessions/{session_id}/statements/{statement_id}"
            )
            if result["state"] == "available":
                break
            if result["state"] in {"error", "cancelled", "cancelling"}:
                raise RuntimeError(f"Cell {number} entered {result['state']}")
            time.sleep(2)
        output = result.get("output") or {}
        if output.get("status") != "ok":
            raise RuntimeError(f"Cell {number} failed: {output}")
        print(f"PASS cell {number}")
finally:
    request("DELETE", f"/sessions/{session_id}")
