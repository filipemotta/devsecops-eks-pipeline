# End-to-End DevSecOps on EKS — companion repository

Companion code for the article *"End-to-End DevSecOps on EKS: Every Stage Blocks, or
It's Theater"*. Every artifact here is executable, and `validate.sh` runs the static
validation gate (terraform validate, kubeconform, shellcheck) over the whole repo.

Two ways to run it end to end:

- **Path A — local, free (kind):** everything except live Falco runtime detection, which
  needs a Linux kernel with BTF. Best for the admission-control and scanning stages.
- **Path B — real EKS (cheap, learning only):** a single-node cluster so Falco runtime
  and real admission behave as in production. **This costs money and is not production.**

## Layout

```
app/         Demo Flask service + hardened Dockerfile (the thing being protected)
infra/       Terraform support infra (ECR, S3, KMS) — scanned with trivy config
ci/          GitHub Actions pipeline: gitleaks -> semgrep -> trivy fs+config -> build -> cosign sign+attest -> OIDC terraform -> DefectDojo
policies/    Kyverno policies (signature, SBOM attestation, pod security, no :latest, ephemeral) + RBAC
k8s/         Demo Deployment + ExternalSecret reference (secrets management)
runtime/     Falco + Falcosidekick Helm values with custom rules
defectdojo/  DefectDojo bootstrap notes + report import script
cluster/     kind config for the local POC
validate.sh  Static validation gate (run this first)
.pre-commit-config.yaml   Local shift-left: gitleaks + trivy config before every commit
```

## Prerequisites

Common: `docker`, `kubectl`, `helm`, `trivy`, `gitleaks`.
Path A also needs `kind`. Path B also needs `awscli` (configured) and `eksctl`.
Tested with trivy 0.74.x, gitleaks 8.30.x, Kyverno 1.19 (chart 3.9.x).

---

## Step 0 — Static validation (both paths, no cost)

```bash
bash validate.sh
# also scan for secrets and IaC misconfig, exactly like CI gates 1 and 3:
gitleaks dir --redact .
trivy config --exit-code 1 --severity HIGH,CRITICAL infra/     # passes
mv infra/insecure.tf.example infra/insecure.tf
trivy config --exit-code 1 --severity HIGH,CRITICAL infra/     # fails: 5 HIGH
mv infra/insecure.tf infra/insecure.tf.example
```

## Step 1 — Build and scan the image (both paths, no cost)

```bash
docker build -t payments-demo:v0.1.0 app/
trivy image --exit-code 1 --severity HIGH,CRITICAL payments-demo:v0.1.0   # gate 4
# Try the slim base to watch the gate fail (see the article):
# change the Dockerfile FROM to python:3.12-slim, rebuild, and re-scan.
```

---

## Path A — Local cluster (kind)

### A2 — Cluster + Kyverno

```bash
kind create cluster --name devsecops --config cluster/kind-config.yaml
helm repo add kyverno https://kyverno.github.io/kyverno && helm repo update
helm install kyverno kyverno/kyverno -n kyverno --create-namespace --wait

kubectl apply -f policies/kyverno/pod-security-baseline.yaml
kubectl apply -f policies/kyverno/disallow-latest-tag.yaml
kubectl apply -f policies/kyverno/restrict-ephemeral-containers.yaml
# require-image-signature.yaml and require-sbom-attestation.yaml need a CI-signed
# image on a registry; apply them on Path B after replacing OWNER/REPO.
```

### A3 — Watch the gates block, then admit the good workload

```bash
kubectl create ns demo
kubectl run bad --image=nginx:latest -n demo                    # denied: :latest tag
kubectl run root --image=nginx:1.27 -n demo \
  --overrides='{"spec":{"containers":[{"name":"root","image":"nginx:1.27","securityContext":{"privileged":true}}]}}'
                                                                # denied: pod security
kind load docker-image payments-demo:v0.1.0 --name devsecops
sed 's#ghcr.io/OWNER/payments-demo:v0.1.0#docker.io/library/payments-demo:v0.1.0#' \
  k8s/deployment.yaml | kubectl apply -f -                      # admitted
kubectl -n demo rollout status deploy/payments-demo
```

### A4 — Break-glass: the ephemeral-container side door

```bash
POD=$(kubectl -n demo get pod -l app=payments-demo -o name | head -1)
# Delete the ephemeral policy first to see the gap, then re-apply to see it close:
kubectl delete -f policies/kyverno/restrict-ephemeral-containers.yaml
kubectl debug "$POD" -n demo --image=alpine:latest -- sleep 300  # admitted (the side door)
kubectl apply -f policies/kyverno/restrict-ephemeral-containers.yaml
kubectl debug "$POD" -n demo --image=alpine:latest -- sleep 300  # now DENIED at /image
```

> Falco runtime detection needs a Linux kernel with BTF and does not load on
> Docker Desktop's macOS VM. Use Path B (or a Linux host) for the runtime stage.

### A5 — Teardown

```bash
kind delete cluster --name devsecops
```

---

## Path B — Real EKS (cheap, learning/reproduction only)

> ⚠️ **This is not a production cluster.** One node, Spot capacity (interruptible), a
> single managed node group, no high availability. It exists so you can see Falco
> runtime detection and real EKS admission. **It costs money:** the EKS control plane
> bills about **US$0.10/hour (~US$73/month) per cluster on its own**, regardless of
> nodes, plus the EC2/EBS for the node. **Create it, run the steps, and delete it the
> same day.** Do not leave it running.

### B1 — Create a minimal cluster (~5–10 min)

```bash
eksctl create cluster \
  --name devsecops-lab \
  --region us-east-1 \
  --version 1.33 \
  --nodes 1 --node-type t3.medium \
  --managed --spot \
  --node-volume-size 20
# t3.medium (4 GiB) fits Kyverno + Falco + the demo; t3.small (2 GiB) is usually too tight.
# Spot keeps the node cheap; being interruptible is fine for a lab.
kubectl config current-context   # should point at devsecops-lab
```

### B2 — Same installs as Path A

```bash
helm repo add kyverno https://kyverno.github.io/kyverno && helm repo update
helm install kyverno kyverno/kyverno -n kyverno --create-namespace --wait
kubectl apply -f policies/kyverno/pod-security-baseline.yaml
kubectl apply -f policies/kyverno/disallow-latest-tag.yaml
kubectl apply -f policies/kyverno/restrict-ephemeral-containers.yaml
```

### B3 — Runtime detection with Falco (the part kind cannot do)

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts && helm repo update
# Ship the Slack webhook from a Secret, never in values committed to Git.
helm install falco falcosecurity/falco -n falco --create-namespace \
  -f runtime/falco-values.yaml --wait
kubectl -n falco get pods                 # falco DaemonSet should be Running on the node
# deploy the demo, then trigger the shell rule and watch the alert:
sed 's#ghcr.io/OWNER/payments-demo:v0.1.0#docker.io/library/payments-demo:v0.1.0#' \
  k8s/deployment.yaml | kubectl apply -f -   # (or push your own image and keep the ref)
kubectl exec -n demo deploy/payments-demo -- sh -c "id"   # fires "Shell in demo container"
```

### B4 — The CI-signed image and its admission policies (optional, full loop)

To exercise `require-image-signature.yaml` and `require-sbom-attestation.yaml`, run the
pipeline in `ci/devsecops-pipeline.yaml` from your own fork so it builds, signs and
attests an image under your identity, then replace `OWNER/REPO` in those policies and
apply them. See "CI setup" below.

### B5 — Teardown (do this when done — it stops the billing)

```bash
eksctl delete cluster --name devsecops-lab --region us-east-1
```

---

## CI setup (GitHub Actions)

`ci/devsecops-pipeline.yaml` goes to `.github/workflows/` in your fork. It needs:

- **GHCR** enabled (the built-in `GITHUB_TOKEN` pushes the image).
- **OIDC to AWS**: an IAM role whose trust policy allows your repo via the GitHub OIDC
  provider; put its ARN in the `terraform-apply` job. No static AWS keys.
- **DefectDojo** reachable, with repo secrets `DD_URL` and `DD_TOKEN`.
- Replace the `OWNER/REPO` placeholders in `policies/kyverno/require-image-signature.yaml`
  and `require-sbom-attestation.yaml` with your GitHub identity.

## DefectDojo (the memory)

See `defectdojo/README.md`. Quick local start with `docker compose`, grab an API token,
then `DD_URL=... DD_TOKEN=... ./defectdojo/import-findings.sh <reports-dir>`.
