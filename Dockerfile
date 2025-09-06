ARG PYTHON_VERSION=3.12

# === BUILD STAGE ===
FROM python:${PYTHON_VERSION} AS build

RUN --mount=type=cache,target=/var/cache/buildkit/pip \
    pip install --root-user-action=ignore --upgrade pip && \
    pip wheel --wheel-dir /wheels mysqlclient

# === RUNTIME STAGE ===
FROM python:${PYTHON_VERSION}-slim

ENV PYTHONUNBUFFERED=1
WORKDIR /app

# System deps
RUN apt update && apt install -y \
    default-libmysqlclient-dev \
    git \
    && apt clean

# Install MySQL client wheel from build stage
COPY --from=build /wheels /wheels
RUN --mount=type=cache,target=/var/cache/buildkit/pip \
    pip install --root-user-action=ignore --find-links /wheels --no-index mysqlclient

# Psycopg2 binary
RUN --mount=type=cache,target=/var/cache/buildkit/pip \
    pip install --root-user-action=ignore "psycopg[binary]"

# Install dependencies
COPY requirements.txt .
RUN --mount=type=cache,target=/var/cache/buildkit/pip \
    pip install --root-user-action=ignore -r requirements.txt

# Copy app code
COPY . /app/
COPY bugsink/conf_templates/docker.py.template bugsink_conf.py

# Install in editable mode
RUN pip install --root-user-action=ignore -e .

# Create user and data dir
RUN groupadd -g 14237 -f bugsink && \
    (id -u bugsink || useradd -u 14237 -g bugsink bugsink) && \
    mkdir -p /data && \
    chown -R 14237:14237 /data

USER bugsink

# Run migrations for Snappea
RUN ["bugsink-manage", "migrate", "snappea", "--database=snappea"]

# Healthcheck
HEALTHCHECK CMD python -c 'import requests; requests.get("http://localhost:8000/health/ready").raise_for_status()'

# Entrypoint
CMD bash -c "\
    monofy bugsink-show-version && \
    bugsink-manage check --deploy --fail-level WARNING && \
    bugsink-manage migrate && \
    bugsink-manage prestart && \
    gunicorn --config bugsink/gunicorn.docker.conf.py --bind=0.0.0.0:$PORT --access-logfile - bugsink.wsgi || bugsink-runsnappea"
