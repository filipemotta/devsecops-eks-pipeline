"""Minimal demo service for the DevSecOps pipeline.

The app is intentionally boring: the pipeline around it is the subject.
"""
from flask import Flask, jsonify

app = Flask(__name__)


@app.get("/")
def index():
    return jsonify(service="payments-demo", status="ok")


@app.get("/healthz")
def healthz():
    return jsonify(status="healthy")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
