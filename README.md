# End-to-End DevSecOps on EKS — companion repository

Companion code for the article *"End-to-End DevSecOps on EKS: Every Stage Blocks, or
It's Theater"*. Every artifact here is executable, and `validar.sh` runs the static
validation gate (terraform validate, kubeconform, shellcheck) over the whole repo.

## Layout

```
app/         Demo Flask service + hardened Dockerfile (the thing being protected)
infra/       Terraform support infra (ECR, S3, KMS) — scanned with trivy config
ci/          GitHub Actions pipeline: gitleaks → semgrep → trivy fs+config → build → cosign sign+attest → OIDC terraform → DefectDojo
policies/    Kyverno policies (signature, SBOM attestation, pod security, no :latest, ephemeral) + RBAC
k8s/         Demo Deployment + ExternalSecret reference (secrets management)
.pre-commit-config.yaml   Local shift-left: gitleaks + trivy config before every commit
runtime/     Falco + Falcosidekick Helm values with custom rules
defectdojo/  DefectDojo bootstrap notes + report import script
cluster/     kind config for the local POC
```

## Prerequisites

docker, kind, kubectl, helm, trivy, gitleaks. For the CI pipeline: a GitHub repo with
GHCR enabled and DefectDojo reachable (secrets `DD_URL`, `DD_TOKEN`). Tested with
trivy 0.74.x, gitleaks 8.30.x, Kyverno 1.19 (chart 3.9.x).

## Execution order (local POC)

```bash
# 0. Static validation of everything in this repo
bash validar.sh

# 1. Build and scan the image locally (what CI's gates 3-4 do)
docker build -t payments-demo:v0.1.0 app/
trivy image --exit-code 1 --severity HIGH,CRITICAL payments-demo:v0.1.0

# 2. Secrets scan (gate 1) + IaC scan (gate 3, the Checkov role)
gitleaks dir --redact .
trivy config --exit-code 1 --severity HIGH,CRITICAL infra/        # secure infra passes
mv infra/insecure.tf.example infra/insecure.tf
trivy config --exit-code 1 --severity HIGH,CRITICAL infra/        # now fails: 5 HIGH
mv infra/insecure.tf infra/insecure.tf.example

# 3. Local cluster + Kyverno
kind create cluster --name devsecops --config cluster/kind-config.yaml
helm repo add kyverno https://kyverno.github.io/kyverno && helm repo update
helm install kyverno kyverno/kyverno -n kyverno --create-namespace
kubectl apply -f policies/kyverno/pod-security-baseline.yaml
kubectl apply -f policies/kyverno/disallow-latest-tag.yaml
kubectl apply -f policies/kyverno/restrict-ephemeral-containers.yaml
# (require-image-signature.yaml needs the CI-signed image; apply on EKS after
#  replacing OWNER/REPO. policies/rbac/ needs a real SRE group.)

# 4. Watch the gates close
kubectl create ns demo
kubectl run bad --image=nginx:latest -n demo          # denied: :latest tag
kubectl run root --image=nginx:1.27 -n demo \
  --overrides='{"spec":{"containers":[{"name":"root","image":"nginx:1.27","securityContext":{"privileged":true}}]}}'
                                                      # denied: baseline pod security
kubectl apply -f k8s/deployment.yaml                  # admitted (after image swap)

# 4b. Break-glass: the ephemeral-container side door, opened then closed
kubectl debug <pod> -n demo --image=alpine:latest --target=<c> -- sleep 300
#   ^ admitted while only the 3 base policies are applied (spec.containers gap)
kubectl apply -f policies/kyverno/restrict-ephemeral-containers.yaml
kubectl debug <pod> -n demo --image=alpine:latest --target=<c> -- sleep 300
#   ^ now DENIED at /image; a compliant (pinned, non-root) debug is admitted

# 5. Runtime detection
helm repo add falcosecurity https://falcosecurity.github.io/charts && helm repo update
helm install falco falcosecurity/falco -n falco --create-namespace \
  -f runtime/falco-values.yaml
kubectl exec -n demo deploy/payments-demo -- sh -c "id"   # triggers the shell rule

# 6. DefectDojo as the program's memory
# see defectdojo/README.md, then:
DD_URL=... DD_TOKEN=... ./defectdojo/import-findings.sh <reports-dir>

# Teardown
kind delete cluster --name devsecops
```

On EKS the flow is identical from step 3 onward — point kubectl at the EKS cluster,
keep the same Helm installs and policies, and let CI (ci/devsecops-pipeline.yaml)
build, sign and push the image that `require-image-signature` verifies.
