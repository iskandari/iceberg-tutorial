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

## Download (each R user)

```bash
git clone https://github.com/iskandari/iceberg-tutorial.git
cd iceberg-tutorial
```

In RStudio, install the two client packages once:

```r
install.packages(c("sparklyr", "DBI"))
```

## Connect from RStudio

Keep this authenticated SSM tunnel open:

```bash
aws sso login --profile sso-admin
./scripts/tunnel-livy.sh CLUSTER_ID
```

Then open [`examples/vpts.R`](examples/vpts.R) in local RStudio and run it. It lists Iceberg tables, retrieves a filtered profile sample, and aggregates daily density and flight speed. [`examples/vpi.R`](examples/vpi.R) demonstrates the vertically integrated `vpts.vpi` table. [`examples/questions.R`](examples/questions.R) asks five migration and data-quality questions. Up to five learners get separate, fairly capped Livy/Spark sessions; no AWS ports are public.

Users need radar-account SSO permissions for EMR read access and `ssm:StartSession`. CU VPN may remain connected, but Cornell's split tunnel does not provide an AWS-routable VPN source address.

If a colleague has a different profile name, prefix commands with `AWS_PROFILE=their-profile`. Do not share the `sso-admin` login.

## Jupyter

Open the existing EMR Studio `Studio_1`, create a Workspace, attach `vpts-iceberg-r-tutorial`, and run [`examples/vpts.py`](examples/vpts.py).

## Configuration

EMR 7.12 supplies compatible Hadoop, AWS SDK, S3, and Iceberg libraries. The config adds Spark 3.5/Scala 2.12 builds of Sedona, GeoTools, and MongoDB. This replaces the local mixed Spark 3.2/3.4/3.5 and Scala 2.12/2.13 jar set.

Credentials come from IAM roles—never put access keys in notebooks.

## Verified

Tested live against EMR on 2026-08-13: all three R scripts passed. A five-user concurrent smoke test passed in 44 seconds. Fresh sessions plus example queries took 42–60 seconds; later queries in an open session avoid startup overhead.

## Stop

```bash
./scripts/terminate.sh CLUSTER_ID
```
