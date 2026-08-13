# VPTS Iceberg with R

Shared EMR cluster for querying `glue_catalog.vpts.data`. RStudio is the primary client; Jupyter is optional.

## Launch (admin)

Prerequisites: AWS CLI, `aws sso login --profile sso-admin`, and the Session Manager plugin.

```bash
./scripts/launch.sh
```

Shape: one `m7i.2xlarge` primary plus four `m7i.4xlarge` workers. The workers provide 64 vCPU and 256 GiB RAM—at least 4× the 64 GiB Mac's memory. The cluster auto-terminates after four idle hours.

Estimated us-east-1 on-demand cost: **about $4.57/hour** ($4.54 EC2 + EMR, plus about $0.04/hour for 320 GiB gp3; S3/network usage extra).

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

Then open [`examples/vpts.R`](examples/vpts.R) in local RStudio and run it. The examples list Iceberg tables, retrieve a filtered sample, and aggregate daily VPTS density and flight speed. Each user gets a separate Livy/Spark session; no AWS ports are public.

Users need radar-account SSO permissions for EMR read access and `ssm:StartSession`. CU VPN may remain connected, but Cornell's split tunnel does not provide an AWS-routable VPN source address.

## Jupyter

Open the existing EMR Studio `Studio_1`, create a Workspace, attach `vpts-iceberg-r-tutorial`, and run [`examples/vpts.py`](examples/vpts.py).

## Configuration

EMR 7.12 supplies compatible Hadoop, AWS SDK, S3, and Iceberg libraries. The config adds Spark 3.5/Scala 2.12 builds of Sedona, GeoTools, and MongoDB. This replaces the local mixed Spark 3.2/3.4/3.5 and Scala 2.12/2.13 jar set.

Credentials come from IAM roles—never put access keys in notebooks.

## Stop

```bash
./scripts/terminate.sh CLUSTER_ID
```
