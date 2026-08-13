# VPTS Iceberg with R

Shared EMR cluster for querying `glue_catalog.vpts.data`. RStudio is the primary client; Jupyter is optional.

## Launch (admin)

Prerequisites: AWS CLI, `aws sso login --profile sso-admin`, and the Session Manager plugin. On macOS:

```bash
brew install --cask session-manager-plugin
```

```bash
./scripts/launch.sh
```

Shape: one `m7i.2xlarge` primary plus four `m7i.4xlarge` workers. The workers provide 64 vCPU and 256 GiB RAM—at least 4× the 64 GiB Mac's memory. The cluster auto-terminates after one idle hour.

Estimated us-east-1 on-demand cost: **about $4.57/hour** ($4.54 EC2 + EMR, plus about $0.04/hour for 320 GiB gp3; S3/network usage extra). A two-hour tutorial is roughly **$9.14**.

## R users: three steps

```bash
git clone https://github.com/iskandari/iceberg-tutorial.git
cd iceberg-tutorial
```

1. Install the clients once:

```r
install.packages(c("sparklyr", "DBI"))
```

2. Keep an authenticated terminal tunnel open:

```bash
aws sso login --profile sso-admin
./scripts/tunnel-livy.sh CLUSTER_ID
```

3. In RStudio, open and run [`examples/vpts.R`](examples/vpts.R).

Other examples: [`vpi.R`](examples/vpi.R), [`questions.R`](examples/questions.R), and the archive-wide [`full_scan.R`](examples/full_scan.R). Up to five learners get independent, fairly capped Spark sessions; no AWS ports are public.

[`examples/full_scan.R`](examples/full_scan.R) scans the complete `vpts.vpi` archive to find the 100 m mean-flight-height bands with the highest VID, and reports its own query time. Use it to demonstrate the cost of omitting Iceberg partition filters.

Users need radar-account SSO permissions for EMR read access and `ssm:StartSession`. CU VPN may remain connected, but Cornell's split tunnel does not provide an AWS-routable VPN source address.

If a colleague has a different profile name, prefix commands with `AWS_PROFILE=their-profile`. Do not share the `sso-admin` login.

## Jupyter

Open the existing EMR Studio `Studio_1`, create a Workspace, attach `vpts-iceberg-r-tutorial`, and run [`examples/vpts.py`](examples/vpts.py).

## Configuration

EMR 7.12 supplies compatible Hadoop, AWS SDK, S3, and Iceberg libraries. The config adds Spark 3.5/Scala 2.12 builds of Sedona, GeoTools, and MongoDB. This replaces the local mixed Spark 3.2/3.4/3.5 and Scala 2.12/2.13 jar set.

Credentials come from IAM roles—never put access keys in notebooks.

## Verified

Tested live on 2026-08-13. Five simultaneous R sessions all queried Iceberg successfully in 42.4 seconds.

| Script | SQL time(s) | Total with new session |
|---|---:|---:|
| `vpts.R` | 6.1, 10.7, 5.7 | 45.1 s |
| `vpi.R` | 5.8, 2.0, 20.1 | 50.3 s |
| `questions.R` | 24.7, 6.1, 5.6, 2.5, 3.5 | 62.5 s |
| `full_scan.R` | 125.2 | 149.0 s |

The archive-wide result placed the highest mean VID in the 900 m height band. Timings vary with concurrent load and cached metadata.

## Stop

```bash
./scripts/terminate.sh CLUSTER_ID
```
