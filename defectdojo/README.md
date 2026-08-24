# DefectDojo — the program's memory

DefectDojo aggregates every scanner's findings, deduplicates them and tracks SLAs.
It is deliberately NOT a gate: gates live in CI and admission; memory lives here.

## Quickstart (docker compose, for the POC)

```bash
git clone https://github.com/DefectDojo/django-DefectDojo
cd django-DefectDojo
docker compose up -d
# initial admin password:
docker compose logs initializer | grep "Admin password:"
```

UI at http://localhost:8080. Create an API v2 key under your user profile
(or read it at /api/key-v2) and export it as `DD_TOKEN`.

## Importing reports

`import-findings.sh` posts each report to `/api/v2/import-scan/` with
`auto_create_context=true`, so product and engagement are created on first import.
`close_old_findings=true` makes each CI run supersede the previous one — findings
that disappear from reports get closed instead of piling up.

`scan_type` must match a DefectDojo parser name exactly. Verify yours with:

```bash
curl -H "Authorization: Token $DD_TOKEN" "$DD_URL/api/v2/test_types/?name=Trivy"
```
