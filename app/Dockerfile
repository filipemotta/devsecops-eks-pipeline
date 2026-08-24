# Hardened Dockerfile: every line here closes a finding Trivy would raise.
#
# Base choice is a gate decision, measured, not guessed (2026-08-23):
#   python:3.12-slim   → 53 HIGH/CRITICAL OS CVEs → trivy gate FAILS
#   python:3.12-alpine → 0 HIGH/CRITICAL          → trivy gate passes
# In production, pin the base by digest (python:3.12-alpine@sha256:...) so the
# image you scanned is the image you run.
FROM python:3.12-alpine

# Non-root from the start: Kyverno's pod-security policy will refuse root anyway.
RUN addgroup -g 10001 app && adduser -u 10001 -G app -D -H app

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY --chown=app:app app.py .

USER 10001:10001
EXPOSE 8080

# Gunicorn instead of the Flask dev server; no shell-form CMD.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app:app"]
