#!/usr/bin/env bash
# Validação padrão do repositorio/ de um post (ADR-0004).
# Copiado de templates/validar.sh pela skill repositorio-post; rode da raiz do repositorio/.
# Ele detecta os tipos de artefato presentes e roda o validador certo.
# Saída serve de evidência para TESTES.md. Falha (exit != 0) se qualquer validação falhar.
set -uo pipefail

FALHAS=0
falha() { echo "  [FALHA] $1"; FALHAS=$((FALHAS + 1)); }
ok()    { echo "  [ok] $1"; }
pula()  { echo "  [pulado] $1 (ferramenta ausente: instale com 'brew install $2')"; }
roda()  { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else falha "$desc"; fi; }

echo "== validar.sh — $(date '+%Y-%m-%d %H:%M') =="

# --- Shell scripts ---
while IFS= read -r s; do
  [ -n "$s" ] || continue
  roda "bash -n $s" bash -n "$s"
  if command -v shellcheck >/dev/null; then
    roda "shellcheck $s" shellcheck "$s"
  else pula "shellcheck $s" shellcheck; fi
done < <(find . -name '*.sh' -not -path './.terraform/*' | sort)

# --- Terraform ---
if find . -name '*.tf' -not -path './.terraform/*' | grep -q .; then
  if command -v terraform >/dev/null; then
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      if (cd "$d" \
        && terraform fmt -check >/dev/null \
        && terraform init -backend=false -input=false >/dev/null \
        && terraform validate >/dev/null); then
        ok "terraform fmt+init+validate em $d"
      else falha "terraform em $d"; fi
    done < <(find . -name '*.tf' -not -path './.terraform/*' -exec dirname {} \; | sort -u)
  else pula "terraform" terraform; fi
fi

# --- Kubernetes YAML ---
k8s_files=()
while IFS= read -r f; do k8s_files+=("$f"); done \
  < <(grep -rlE '^(apiVersion|kind):' --include='*.yaml' --include='*.yml' . 2>/dev/null | sort)
if [ "${#k8s_files[@]}" -gt 0 ]; then
  if command -v kubeconform >/dev/null; then
    # -ignore-missing-schemas: CRDs de terceiros (Karpenter etc.) validam campos na doc oficial
    roda "kubeconform (${#k8s_files[@]} arquivos)" \
      kubeconform -strict -summary -ignore-missing-schemas "${k8s_files[@]}"
  else pula "kubeconform" kubeconform; fi
fi

# --- Helm ---
while IFS= read -r chart; do
  [ -n "$chart" ] || continue
  if command -v helm >/dev/null; then
    roda "helm lint $chart" helm lint "$chart"
    roda "helm template $chart" helm template "$chart"
  else pula "helm $chart" helm; fi
done < <(find . -name Chart.yaml -exec dirname {} \; | sort)

echo "== resultado: $FALHAS falha(s) =="
[ "$FALHAS" -eq 0 ]
