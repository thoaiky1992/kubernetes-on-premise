FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1

RUN pip install --no-cache-dir redis==5.2.1

COPY dump_to_resp.py /app/dump_to_resp.py

USER 65532:65532

ENTRYPOINT ["python3", "/app/dump_to_resp.py"]
