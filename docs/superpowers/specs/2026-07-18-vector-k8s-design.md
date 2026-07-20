# Vector K8s Deployment Design

**Goal:** Containerize the existing Vector topo-sync listener and provide a Helm-based Kubernetes deployment that can run in namespace `uino`, pull from a private registry, and persist configuration on the host at `/data/uinnova/apps/vector`.

## Scope

- Add a thin Vector runtime image that keeps the business config outside the image.
- Add a Helm chart for Kubernetes deployment in namespace `uino`.
- Persist Vector runtime state and editable config on the host under `/data/uinnova/apps/vector`.
- Mount the host Nginx log directory into the pod so Vector can tail the existing access log.
- Keep the sink target and image registry settings configurable through Helm values.

## Design Summary

- The container image will be based on Vector `0.33.1`, matching the currently verified standalone deployment.
- The image will add only one startup script. On startup it will create `/data/uinnova/apps/vector/{config,data}` inside the mounted hostPath, copy a default `vector.toml` from a ConfigMap only when the host copy is missing, and then run `vector --config` against the host file.
- The Helm chart will deploy a single-replica `Deployment` with `Recreate` strategy, root security context for host log readability, and two `hostPath` mounts:
  - `/data/uinnova/apps/vector` for persistent config and checkpoints
  - `/uinnova/nginx/nginx/logs` for the Nginx topo-save log
- The chart will not create a `Service` because this workload only tails files and sends outbound HTTP requests.

## Data Flow

1. Host Nginx writes JSON access logs for topo-save requests.
2. Kubernetes mounts the host log directory into the Vector pod.
3. Vector tails the mounted log file and parses `diagramId`.
4. Vector sends `{"topoId":"..."}` to the configured sync endpoint.
5. Vector checkpoints and buffer data stay in `/data/uinnova/apps/vector/data` on the host.

## Operational Rules

- The first install bootstraps `/data/uinnova/apps/vector/config/vector.toml` from the chart-provided template if the host file does not exist.
- Later host-side edits are preserved because the startup script will not overwrite an existing host config file.
- Helm values control:
  - image repository, tag, pull policy, and pull secrets
  - host paths
  - sync endpoint URI
  - resource requests and limits
  - optional node scheduling fields

## Verification

- Local Helm validation with `helm lint` and `helm template`.
- Local image build validation with `docker build`.
- ARM64 runtime validation on `172.16.3.116` by loading the built image and starting the container with mounted host directories.
