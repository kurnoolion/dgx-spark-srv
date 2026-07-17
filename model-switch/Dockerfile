FROM python:3.12-slim

# Some corporate DPI/firewall devices reset the large post-quantum ClientHello
# that this image's OpenSSL 3.5+ sends by default (host tools on older OpenSSL
# 3.0 pass, so only container TLS appears "blocked" — pip/apt inside the build
# fail with "Connection reset by peer" while identical calls on the host work).
# Pin classical key-exchange groups — universally supported — so pip and any
# HTTPS calls at build time work behind such middleboxes.
RUN printf '%s\n' 'openssl_conf = openssl_init' '[openssl_init]' \
    'ssl_conf = ssl_sect' '[ssl_sect]' 'system_default = system_default_sect' \
    '[system_default_sect]' 'Groups = X25519:P-256:P-384' > /etc/openssl-classical.cnf
ENV OPENSSL_CONF=/etc/openssl-classical.cnf

WORKDIR /app

# curl only for the healthcheck; keep the layer small.
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

ENV PYTHONUNBUFFERED=1
EXPOSE 9000

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "9000", "--log-level", "info"]
