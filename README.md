# VPTS Iceberg with R

Shared EMR cluster for querying `glue_catalog.vpts.data`. RStudio is the primary client; Jupyter is optional.

## Instructor: get everyone started

1. Start the cluster with `AWS_PROFILE=icebird ./scripts/launch.sh` if it is not already running.
2. Send users the repo URL and the `icebird-tutorial` read-only credentials through a secure channel.
3. Ask each user to run the four commands in **Colleague quick start** below.
4. Users leave `tunnel-livy.sh` running, open `iceberg-tutorial.Rproj` in RStudio, and source `examples/vpts.R`.
5. Show jobs at [localhost:8088](http://localhost:8088) or run `./scripts/list-jobs.sh` for clickable Spark UI links.
6. At the end, users press `Ctrl-C` to close their tunnels; an administrator stops the cluster with `./scripts/terminate.sh CLUSTER_ID`.

## Colleague quick start

The administrator supplies the read-only `icebird-tutorial` AWS access key and secret separately. Never commit credentials to this repository. Keep `icebird` for administrators only.

```bash
git clone https://github.com/iskandari/iceberg-tutorial.git
cd iceberg-tutorial
./scripts/setup-local.sh
./scripts/tunnel-livy.sh
```

`setup-local.sh` checks AWS CLI, R, Session Manager, the `icebird-tutorial` profile, radar-account access, and required R packages. Enter the supplied credentials if `aws configure` prompts.

Keep `tunnel-livy.sh` open. It automatically provides:

- RStudio/Livy: `http://localhost:8998`
- Spark/YARN tasks: [http://localhost:8088](http://localhost:8088)
- Spark ApplicationMaster proxy: `http://localhost:20888`

Open [`iceberg-tutorial.Rproj`](iceberg-tutorial.Rproj), then open [`examples/vpts.R`](examples/vpts.R) and click **Source**.

## Why Iceberg on S3?

- S3 provides inexpensive durable storage without a continuously running database server.
- Spark compute is started only when needed and can be shared by multiple users.
- Iceberg adds schema evolution, partition pruning, transactions, and snapshots to files in S3.
- Hosted PostgreSQL continuously charges for provisioned compute, memory, storage, IOPS, and backups sized for a very large archive.
- DuckDB is excellent for local analysis; Iceberg is better suited to a large shared dataset with concurrent users and distributed Spark queries.

In short, Iceberg separates inexpensive persistent storage from temporary scalable compute.

## Existing users after a repo update

You do not need to reinstall everything. Update the repo, stop the old tunnel with `Ctrl-C`, and restart it:

```bash
cd iceberg-tutorial
git pull
./scripts/tunnel-livy.sh
```

Keep that terminal open. In another terminal, list current jobs and working Spark UI links:

```bash
cd iceberg-tutorial
./scripts/list-jobs.sh
```

RStudio uses `localhost:8998`, YARN uses [localhost:8088](http://localhost:8088), and `list-jobs.sh` prints each application's accessible `localhost:20888` Spark UI link. Rerun `./scripts/setup-local.sh` only if local tools or R packages are missing.

## Launch (admin)

Prerequisites: AWS CLI, `aws sso login --profile sso-admin`, and the Session Manager plugin. On macOS:

```bash
brew install --cask session-manager-plugin
```

```bash
./scripts/launch.sh
```

Shape: one `m7i.2xlarge` primary plus four `m7i.4xlarge` workers. The workers provide 64 vCPU and 256 GiB RAM—at least 4× the 64 GiB Mac's memory. The cluster stays up until an administrator runs `scripts/terminate.sh`.

Estimated us-east-1 on-demand cost: **about $4.57/hour** ($4.54 EC2 + EMR, plus about $0.04/hour for 320 GiB gp3; S3/network usage extra). A two-hour tutorial is roughly **$9.14**. Because there is no idle shutdown, remember to terminate it manually when finished.

## RStudio: connect and work

### One-time setup

Install the tools and clone the repo:

```bash
brew install awscli
brew install --cask session-manager-plugin
git clone https://github.com/iskandari/iceberg-tutorial.git
cd iceberg-tutorial
```

Configure the supplied credentials under the `icebird-tutorial` profile:

```bash
aws configure --profile icebird-tutorial
```

Install/check the R clients:

```bash
Rscript scripts/install-r-packages.R
```

### 1. Open the port

In a terminal, enter the cloned repo and start the tunnel:

```bash
cd iceberg-tutorial
Rscript scripts/install-r-packages.R
./scripts/tunnel-livy.sh
```

This single command opens both Livy for RStudio and the Spark/YARN task UI. Leave the terminal open. Continue when it says:

```text
Port 8998 opened
```

In a second terminal, print each job's status and working local Spark UI link:

```bash
./scripts/list-jobs.sh
```

Open the printed `http://localhost:20888/proxy/application_.../` link. Do not click YARN's **ApplicationMaster** link: it contains a private hostname that laptops cannot resolve. The local link provides Spark's Jobs, Stages, SQL, and Executors tabs. `Ctrl-C` closes all three tunnels.

### 2. Open RStudio

Open [`iceberg-tutorial.Rproj`](iceberg-tutorial.Rproj), open [`examples/vpts.R`](examples/vpts.R), and click **Source**. Spark runs on EMR; results return to RStudio. Stop the tunnel with `Ctrl-C` when finished.

The examples suppress RStudio's unsupported Livy Connections-pane observer. Use the returned R objects and Console output; the Connections pane itself is not available for Livy.

Other examples: [`vpi.R`](examples/vpi.R), [`questions.R`](examples/questions.R), and the archive-wide [`full_scan.R`](examples/full_scan.R). Up to ten learners get independent, fairly capped Spark sessions; no AWS ports are public. Ten simultaneous heavy queries share the cluster, so they may run more slowly than a single query.

[`examples/full_scan.R`](examples/full_scan.R) scans the complete `vpts.vpi` archive to find the 100 m mean-flight-height bands with the highest VID, and reports its own query time. Use it to demonstrate the cost of omitting Iceberg partition filters.

The `icebird-tutorial` IAM user has only EMR discovery and SSM tunnel permissions. The dedicated cluster role can read Glue and `s3://ice.bird`, while explicit IAM denies block S3 writes/deletes and Glue mutations.

If a colleague has a different profile name, prefix commands with `AWS_PROFILE=their-profile`. Do not share the `sso-admin` login.

## Jupyter

Open EMR Studio `Studio_1`, create a Workspace, attach `vpts-iceberg-r-tutorial`, upload and run [`examples/vpts_iceberg_tutorial.ipynb`](examples/vpts_iceberg_tutorial.ipynb). It contains the same timed analyses as the R examples, including the full-archive scan. All 11 code cells were tested successfully through PySpark/Livy.

## Inspect the 2025 extrapolation sample in R

Connect to the existing cluster with the read-only collaborator profile; do not
launch a second cluster:

```bash
./scripts/setup-local.sh
./scripts/tunnel-livy.sh
```

Leave the tunnel running. In another terminal, inspect the production sample:

```bash
Rscript extrapolation/scripts/inspect-production-year.R 2025
```

The script reads the sample directly from
`s3://vpts-extrapolation-863683271215/production/profile_sampled/year=2025/`.
It prints dataset counts, missingness at each of the 50 100-m heights, and one
complete 50-row profile. The shared R helper and EMR defaults configure a larger
Iceberg S3 connection pool and acquisition timeout for stable archive queries.

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
