#!/usr/bin/env python3
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# SPDX-License-Identifier: Apache-2.0
"""Validate deployment inputs and emit Compose JSON (stdlib only, no shell eval)."""
import argparse
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import sys

DEFAULTS = {
    "PROJECT_NAME": "openan", "PUBLIC_PORT": "8080", "PUBLIC_BIND": "0.0.0.0",
    "PUBLIC_ENABLE_HTTPS": "false", "PUBLIC_TLS_DIR": "",
    "FRONTEND_TYPE": "portal",
    "DATABASE_TYPE": "mysql", "DATABASE_INTERNAL": "false", "DB_HOST": "", "DB_PORT": "",
    "REGISTRY_DB_NAME": "registry_center", "REGISTRY_DB_USERNAME": "registry",
    "REGISTRY_DB_PASSWORD": "", "ORCH_DB_NAME": "orchestration_center",
    "ORCH_DB_USERNAME": "orchestration", "ORCH_DB_PASSWORD": "", "POSTGRES_PASSWORD": "", "MYSQL_ROOT_PASSWORD": "",
    "REGISTRY_ENABLE_HTTPS": "false", "REGISTRY_VERIFY_CLIENT": "false", "REGISTRY_TLS_DIR": "",
    "ORCH_ENABLE_HTTPS": "false", "ORCH_VERIFY_CLIENT": "false", "ORCH_TLS_DIR": "",
    "BACKEND_VERIFY_SERVER": "true", "ORCH_CLIENT_VERIFY_SERVER": "true",
    "REGISTRY_PROXY_TLS_DIR": "", "ORCH_PROXY_TLS_DIR": "", "REGISTRY_CLIENT_TLS_DIR": "",
    "REGISTRY_SIGN_ENABLED": "true", "REGISTRY_SIGN_DIR": "", "REGISTRY_PUBLIC_BASE_URL": "",
    "REGISTRY_AUTH_MODE": "static_bearer", "REGISTRY_CREDENTIAL_FILE": "",
    "REGISTRY_MODELS_FILE": "", "ORCH_MODELS_FILE": "",
    "REGISTRY_RUNTIME_ENV_FILE": "", "ORCH_RUNTIME_ENV_FILE": "",
    "REGISTRY_HEALTHCHECK_HOST": "127.0.0.1", "ORCH_HEALTHCHECK_HOST": "127.0.0.1",
}


def read_env(path):
    """Read literal KEY=VALUE; dollar/backtick text is never executed/interpolated."""
    values = {}
    for number, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        key = key.strip()
        if not separator or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key) or key in values:
            raise ValueError(f"Invalid or duplicate key in {Path(path).name}:{number}")
        # Inline comments are allowed only outside quotes. No expansion occurs.
        tokens = shlex.split(value, comments=True, posix=True)
        if len(tokens) > 1:
            raise ValueError(f"Quote values containing whitespace in {Path(path).name}:{number}")
        values[key] = tokens[0] if tokens else ""
    return values


def boolean(config, key):
    value = config[key].lower()
    if value not in {"true", "false"}:
        raise ValueError(f"{key} must be true or false")
    return value == "true"


def required(config, key):
    if not config.get(key):
        raise ValueError(f"{key} is required")
    return config[key]


def input_path(config, key, base, directory=False):
    path = Path(required(config, key))
    path = (base / path).resolve() if not path.is_absolute() else path.resolve()
    if not (path.is_dir() if directory else path.is_file()):
        raise ValueError(f"{key} must name an existing {'directory' if directory else 'file'}")
    return path


def bind(source, target, readonly=True):
    return {"type": "bind", "source": str(source), "target": target,
            "read_only": readonly, "bind": {"create_host_path": False}}


def material(directory, names, label):
    for name in names:
        if not (directory / name).is_file():
            raise ValueError(f"{label} requires {name}")


def tls_proxy(config, role, base, required_client=False):
    if not config[role + "_PROXY_TLS_DIR"] and not required_client:
        if boolean(config, "BACKEND_VERIFY_SERVER"):
            raise ValueError(f"{role}_PROXY_TLS_DIR is required for upstream CA verification")
        return [], "proxy_ssl_verify off;"
    directory = input_path(config, role + "_PROXY_TLS_DIR", base, True)
    target = f"/etc/nginx/pki/{role.lower()}"
    directives = ["proxy_ssl_server_name on;", f"proxy_ssl_name {'registry-center' if role == 'REGISTRY' else 'orchestration-center'};"]
    if boolean(config, "BACKEND_VERIFY_SERVER"):
        material(directory, ["trust.cer"], role + " proxy TLS")
        directives += ["proxy_ssl_verify on;", "proxy_ssl_verify_depth 5;",
                       f"proxy_ssl_trusted_certificate {target}/trust.cer;"]
    else:
        directives += ["proxy_ssl_verify off;"]
    if required_client:
        material(directory, ["client.cer", "client_key.pem"], role + " proxy mTLS")
        directives += [f"proxy_ssl_certificate {target}/client.cer;",
                       f"proxy_ssl_certificate_key {target}/client_key.pem;"]
        if (directory / "cert_pwd").is_file():
            directives += [f"proxy_ssl_password_file {target}/cert_pwd;"]
    return [bind(directory, target)], "\n".join(directives)


def nginx_config(secure, locations, public_tls, portal):
    tls = ""
    if secure:
        tls = "ssl_certificate /etc/nginx/pki/public/server.cer;\nssl_certificate_key /etc/nginx/pki/public/server_key.pem;"
        if (public_tls / "cert_pwd").is_file():
            tls += "\nssl_password_file /etc/nginx/pki/public/cert_pwd;"
    blocks = []
    upstreams = {}
    for prefix, backend, protocol, directives in locations:
        upstream = backend.split(":", 1)[0].replace("-", "_")
        upstreams[upstream] = f"""upstream {upstream} {{
    zone {upstream} 64k;
    server {backend} resolve;
  }}"""
        # Exact prefix redirect plus ^~ prevents asset regex or SPA fallback from
        # swallowing API paths. A trailing slash strips only the proxy prefix.
        uri = "/" if prefix in {"/registry/", "/api/orchestrate/", "/api/registry/"} else ""
        browser_policy = 'proxy_set_header X-OpenAN-Browser-Gateway "1";' if prefix in {
            "/api/orchestrate/", "/rest/v1/orchestrate/", "/api/registry/",
        } else ""
        blocks.append(f"""
location = {prefix.rstrip('/')} {{ return 308 {prefix}; }}
location ^~ {prefix} {{
  proxy_pass {protocol}://{upstream}{uri};
  proxy_http_version 1.1;
  proxy_set_header Connection "";
  proxy_set_header Host $host;
  proxy_set_header X-Real-IP $remote_addr;
  proxy_set_header X-Forwarded-For $remote_addr;
  proxy_set_header X-Forwarded-Proto $scheme;
  proxy_set_header Authorization $http_authorization;
  {browser_policy}
  gzip off;
  proxy_buffering off;
  proxy_read_timeout 3600s;
  {directives}
}}""")
    if portal:
        # The portal container serves its own statics and internal routes on
        # 8080; the public proxy only forwards the unified web entry to it.
        upstreams["portal"] = """upstream portal {
    zone portal 64k;
    server openan-portal:8080 resolve;
  }"""
        # Portal mode drops the static web locations: the portal serves them.
        documents = ""
        statics = ""
        entry = """location / {
  proxy_pass http://portal/;
  proxy_http_version 1.1;
  proxy_set_header Connection "";
  proxy_set_header Host $host;
  proxy_set_header X-Real-IP $remote_addr;
  proxy_set_header X-Forwarded-For $remote_addr;
  proxy_set_header X-Forwarded-Proto $scheme;
  proxy_set_header Authorization $http_authorization;
}"""
    else:
        documents = "root /usr/share/nginx/html;\n    index index.html;"
        statics = """    location ~ "^/assets/[^/]+-[A-Za-z0-9_-]{8,}\\\\.(js|css|svg|png|jpg|woff2)$" {
      try_files $uri =404;
      add_header Cache-Control "public, max-age=31536000, immutable";
      add_header X-Content-Type-Options nosniff always;
      add_header X-Frame-Options SAMEORIGIN always;
      add_header Content-Security-Policy "default-src 'self'; frame-ancestors 'self'" always;
      add_header Referrer-Policy "strict-origin-when-cross-origin" always;
      add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()" always;
    }
    location = /index.html {
      add_header Cache-Control "no-store";
      add_header X-Content-Type-Options nosniff always;
      add_header X-Frame-Options SAMEORIGIN always;
      add_header Content-Security-Policy "default-src 'self'; frame-ancestors 'self'" always;
      add_header Referrer-Policy "strict-origin-when-cross-origin" always;
      add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()" always;
    }
"""
        entry = "location / { try_files $uri $uri/ /index.html; }"
    # Access logs intentionally omit query strings (may contain user intent).
    return f"""worker_processes auto;
events {{ worker_connections 1024; }}
http {{
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  log_format safe '$remote_addr $request_method $uri $status';
  access_log /var/log/nginx/access.log safe;
  client_max_body_size 50m;
  # Docker's embedded DNS; backend replacement must not require a proxy restart.
  resolver 127.0.0.11 valid=2s ipv6=off;
  resolver_timeout 5s;
  {' '.join(upstreams.values())}
  server {{
    listen {443 if secure else 80}{' ssl' if secure else ''};
    server_name _;
    {tls}
    {documents}
    gzip on;
    gzip_vary on;
    gzip_types text/css application/javascript image/svg+xml;
    # Security response headers (issue #55); add_header is not inherited into
    # locations that set their own headers — statics below repeat the set.
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Content-Security-Policy "default-src 'self'; frame-ancestors 'self'" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()" always;
    {''.join(blocks)}
{statics}    # X-XSS-Protection intentionally omitted: deprecated legacy filter.
    {entry}
  }}
}}
"""


def plan(config_file, bundle, arch):
    config_file, bundle = Path(config_file).resolve(), Path(bundle).resolve()
    supplied = read_env(config_file)
    unknown = set(supplied) - set(DEFAULTS)
    if unknown:
        raise ValueError("Unknown deployment keys: " + ", ".join(sorted(unknown)))
    config, base = {**DEFAULTS, **supplied}, config_file.parent
    for key in DEFAULTS:
        if key.endswith("_HTTPS") or key in {"DATABASE_INTERNAL", "REGISTRY_VERIFY_CLIENT", "ORCH_VERIFY_CLIENT",
                                              "BACKEND_VERIFY_SERVER", "ORCH_CLIENT_VERIFY_SERVER", "REGISTRY_SIGN_ENABLED"}:
            boolean(config, key)
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", config["PROJECT_NAME"]):
        raise ValueError("Invalid PROJECT_NAME")
    ipaddress.IPv4Address(config["PUBLIC_BIND"])
    for key in ("PUBLIC_PORT", "DB_PORT"):
        if config[key] and (not config[key].isdigit() or not 1 <= int(config[key]) <= 65535):
            raise ValueError(f"Invalid {key}")
    db = config["DATABASE_TYPE"]
    internal = boolean(config, "DATABASE_INTERNAL")
    if db not in {"mysql", "postgresql"}:
        raise ValueError("DATABASE_TYPE supports mysql/postgresql")
    if config["FRONTEND_TYPE"] not in {"portal", "workflow-designer"}:
        raise ValueError("FRONTEND_TYPE supports portal/workflow-designer")
    portal = config["FRONTEND_TYPE"] == "portal"
    if config["REGISTRY_DB_NAME"] == config["ORCH_DB_NAME"]:
        raise ValueError("Registry and orchestration require distinct databases")
    if internal and config["REGISTRY_DB_USERNAME"] == config["ORCH_DB_USERNAME"]:
        raise ValueError("Internal SQL requires distinct application users")
    legacy = bundle / "compose/data/postgres"
    if legacy.is_dir() and any(legacy.iterdir()):
        raise ValueError("Legacy PostgreSQL data requires explicit backup/restore migration")
    previous = bundle / "runtime/compose.json"
    if previous.is_file() and json.loads(previous.read_text(encoding="utf-8"))["name"] != config["PROJECT_NAME"]:
        raise ValueError("PROJECT_NAME must remain stable for an existing deployment")
    for key in ("REGISTRY_DB_NAME", "ORCH_DB_NAME", "REGISTRY_DB_USERNAME", "ORCH_DB_USERNAME"):
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", required(config, key)):
            raise ValueError(f"Invalid {key}")
    manifest = json.loads((bundle / "deps/image-tags.json").read_text(encoding="utf-8"))
    if arch not in manifest["architectures"]:
        raise ValueError("Bundle does not contain this architecture")
    images = manifest["images"]
    volumes, services, locations = [], {}, []
    for role, service, home, port in [("REGISTRY", "registry-center", "/opt/registry-center", 5000),
                                      ("ORCH", "orchestration-center", "/opt/orchestration-center", 5001)]:
        secure, verify_client = boolean(config, role + "_ENABLE_HTTPS"), boolean(config, role + "_VERIFY_CLIENT")
        if verify_client and not secure:
            raise ValueError(f"{role}_VERIFY_CLIENT requires HTTPS")
        env = read_env(input_path(config, role + "_RUNTIME_ENV_FILE", base))
        managed = {f"{role}_IP": "0.0.0.0", f"{role}_PORT": str(port),
                   f"{role}_ENABLE_HTTPS": str(secure).lower(), f"{role}_VERIFY_CLIENT": str(verify_client).lower(),
                   f"{role}_FORWARDED_ALLOW_IPS": "127.0.0.1", "PERSISTENCE_MODE": db,
                   "DB_HOST": ("openan-postgres" if db == "postgresql" else "openan-mysql") if internal else required(config, "DB_HOST"),
                   "DB_PORT": config["DB_PORT"] or ("5432" if db == "postgresql" else "3306"),
                   "DB_NAME": config[role + "_DB_NAME"], "DB_USERNAME": config[role + "_DB_USERNAME"],
                   "DB_PASSWORD": required(config, role + "_DB_PASSWORD"),
                   "LLM_CONFIG_FILE": home + "/etc/config/models.yaml"}
        mounts = [bind(input_path(config, role + "_MODELS_FILE", base), managed["LLM_CONFIG_FILE"])]
        for folder in ("data", "log"):
            mounts.append(bind(bundle / "runtime" / service / folder, home + "/" + folder, False))
        if role == "REGISTRY":
            if config["REGISTRY_AUTH_MODE"] not in {"static_bearer", "oauth2_jwt", "oauth2_introspection"}:
                raise ValueError("REGISTRY_AUTH_MODE must be a built-in Bearer authentication mode")
            managed.update(REGISTRY_STARTUP_STRICT_IDENTITY="true", REGISTRY_OWNER_IDENTITY_MODE="token",
                           REGISTRY_INTEGRATION_ENABLED="false", REGISTRY_USE_VECTORDB="false",
                           REGISTRY_INTEGRATION_AUTH_MODE=config["REGISTRY_AUTH_MODE"],
                           REGISTRY_REGISTRY_SIGN_ENABLED=config["REGISTRY_SIGN_ENABLED"],
                           REGISTRY_REGISTRY_PUBLIC_BASE_URL=config["REGISTRY_PUBLIC_BASE_URL"])
            required(env, "INTEGRATION_FINGERPRINT_KEY")
            if config["REGISTRY_AUTH_MODE"] == "static_bearer":
                required(env, "INTEGRATION_TOKEN_HMAC_KEY")
                credential = input_path(config, "REGISTRY_CREDENTIAL_FILE", base)
                mounts.append(bind(credential, home + "/etc/conf/integration_credentials.conf"))
            if boolean(config, "REGISTRY_SIGN_ENABLED"):
                signing = input_path(config, "REGISTRY_SIGN_DIR", base, True)
                material(signing, ["sign.cer", "sign_key.pem", "cert_pwd"], "Registry signing")
                mounts.append(bind(signing, home + "/etc/sign_cert"))
        else:
            for key in ("OC_ADMIN_INITIAL_PASSWORD", "REGISTRY_ACCESS_TOKEN"):
                required(env, key)
            managed.update(ORCH_PUBLIC_SCHEME="https" if boolean(config, "PUBLIC_ENABLE_HTTPS") else "http",
                           ORCH_EXTERNAL_AUTH_MODE="user", ORCH_CLIENT_VERIFY_SERVER=config["ORCH_CLIENT_VERIFY_SERVER"],
                           AGENT_REGISTRY_URL=f"{'https' if boolean(config, 'REGISTRY_ENABLE_HTTPS') else 'http'}://registry-center:5000")
            if boolean(config, "REGISTRY_ENABLE_HTTPS"):
                if config["REGISTRY_CLIENT_TLS_DIR"]:
                    client = input_path(config, "REGISTRY_CLIENT_TLS_DIR", base, True)
                    mounts.append(bind(client, home + "/etc/registry_tls"))
                    if boolean(config, "ORCH_CLIENT_VERIFY_SERVER"):
                        material(client, ["trust.cer"], "Registry client")
                        managed["REGISTRY_CA_FILE"] = home + "/etc/registry_tls/trust.cer"
                    if boolean(config, "REGISTRY_VERIFY_CLIENT"):
                        material(client, ["client.cer", "client_key.pem"], "Registry client mTLS")
                        managed.update(REGISTRY_CLIENT_CERT=home + "/etc/registry_tls/client.cer",
                                       REGISTRY_CLIENT_KEY=home + "/etc/registry_tls/client_key.pem")
                elif boolean(config, "ORCH_CLIENT_VERIFY_SERVER") or boolean(config, "REGISTRY_VERIFY_CLIENT"):
                    raise ValueError("REGISTRY_CLIENT_TLS_DIR is required for registry TLS")
        if secure:
            directory = input_path(config, role + "_TLS_DIR", base, True)
            material(directory, ["server.cer", "server_key.pem", "cert_pwd", "trust.cer"], role + " TLS/probe")
            mounts.append(bind(directory, home + "/etc/ssl"))
            managed[role + "_HEALTHCHECK_HOST"] = config[role + "_HEALTHCHECK_HOST"]
            if verify_client:
                material(directory, ["probe-client.cer", "probe-client.key"], role + " mTLS probe")
                managed.update({role + "_HEALTHCHECK_CLIENT_CERT": home + "/etc/ssl/probe-client.cer",
                                role + "_HEALTHCHECK_CLIENT_KEY": home + "/etc/ssl/probe-client.key"})
            proxy_mounts, directives = tls_proxy(config, role, base, verify_client)
            volumes.extend(proxy_mounts)
        else:
            directives = ""
        if role == "REGISTRY":
            prefixes = ["/registry/"] + (["/api/registry/"] if portal else [])
        else:
            prefixes = ["/api/orchestrate/", "/rest/v1/orchestrate/", "/api/v1/orchestrate/"]
        for prefix in prefixes:
            locations.append((prefix, service + f":{port}", "https" if secure else "http", directives))
        conflicts = set(env) & set(managed)
        # Canonical service prefix aliases for database keys must not create a
        # second fact source beside the managed DB_* values.
        conflicts |= {key for key in env if key.startswith(("DB_", "MYSQL_", "POSTGRES_", "POSTGRESQL_",
                                                           "REGISTRY_MYSQL_", "REGISTRY_POSTGRESQL_",
                                                           "ORCH_MYSQL_", "ORCH_POSTGRESQL_",
                                                           "REGISTRY_SSL_", "ORCH_SSL_")) or
                      key in {"PORT", "ENABLE_HTTPS", "APP_HOME", "DATABASE_CONFIG_DIR",
                              "PG_CONNECT_TIMEOUT", "REGISTRY_PERSISTENCE_MODE", "ORCH_PERSISTENCE_MODE"}}
        if conflicts:
            raise ValueError(f"{role} runtime env overrides managed keys: {', '.join(sorted(conflicts))}")
        services[service] = {"image": images[service], "pull_policy": "never", "restart": "unless-stopped",
                             "environment": {**env, **managed}, "volumes": mounts, "networks": ["openan"],
                             "healthcheck": {"test": ["CMD", "python", "-m", "agent_registry.healthcheck" if role == "REGISTRY" else "orchestrate.server.healthcheck"],
                                             "interval": "10s", "timeout": "10s", "retries": 12, "start_period": "40s"}}
        if internal:
            services[service]["depends_on"] = {"openan-postgres" if db == "postgresql" else "openan-mysql": {"condition": "service_healthy"}}
    # OC consumes the registry (agent cards) at runtime; start it only after the
    # registry is healthy so a slow registry start cannot race OC's first contact.
    services["orchestration-center"].setdefault("depends_on", {})["registry-center"] = {"condition": "service_healthy"}
    # Wait for the database to accept an application-level connection before
    # starting OC: the DB healthcheck (root SELECT 1 / pg_isready) can pass
    # while the app user's grant is still propagating, crashing
    # MySQLBackend.__init__ / the psycopg2 pool. The probe selects the right
    # driver from PERSISTENCE_MODE and reads credentials from the container
    # environment at runtime, never from compose.json.
    services["orchestration-center"]["command"] = [
        "sh", "-c",
        "until python3 -c \""
        "import os; mode=os.environ.get('PERSISTENCE_MODE','postgresql'); "
        "kw=dict(host=os.environ.get('DB_HOST','openan-postgres'), "
        "port=int(os.environ.get('DB_PORT','5432')), "
        "user=os.environ['DB_USERNAME'], "
        "password=os.environ['DB_PASSWORD'], "
        "connect_timeout=2); "
        "conn=(__import__('pymysql').connect(database=os.environ.get('DB_NAME','orchestration_center'), **kw) "
        "if mode=='mysql' else "
        "__import__('psycopg2').connect(dbname=os.environ.get('DB_NAME','orchestration_center'), **kw)); "
        "conn.close()\" 2>/dev/null; do "
        "echo 'waiting for database at '\"$DB_HOST\"':'\"$DB_PORT\"'...'; sleep 2; done; "
        "exec python3 -m orchestrate.start"]
    if portal:
        if "portal" not in images:
            raise ValueError("FRONTEND_TYPE=portal requires a portal image in deps/image-tags.json")
        # The portal image renders its own nginx config from its shipped
        # template; only the backend URLs are injected, scheme per backend TLS.
        services["openan-portal"] = {"image": images["portal"], "pull_policy": "never", "restart": "unless-stopped",
                                     "environment": {"BACKEND_URL": ("https" if boolean(config, "ORCH_ENABLE_HTTPS") else "http") + "://orchestration-center:5001",
                                                     "REGISTRY_URL": ("https" if boolean(config, "REGISTRY_ENABLE_HTTPS") else "http") + "://registry-center:5000"},
                                     "networks": ["openan"],
                                     "healthcheck": {"test": ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8080/"],
                                                     "interval": "10s", "timeout": "5s", "retries": 12, "start_period": "10s"}}
    if config["REGISTRY_AUTH_MODE"] == "static_bearer":
        # Fail before containers start if OC's registry credential is unprovisioned.
        rcenv, ocenv = services["registry-center"]["environment"], services["orchestration-center"]["environment"]
        digest = hmac.new(rcenv["INTEGRATION_TOKEN_HMAC_KEY"].encode(), ocenv["REGISTRY_ACCESS_TOKEN"].encode(), hashlib.sha256).hexdigest()
        credentials = {}
        for line in credential.read_text(encoding="utf-8").splitlines():
            if line.strip() and not line.lstrip().startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                credentials[key.strip()] = value.strip()
        valid = any(hmac.compare_digest(value, digest) and
                    credentials.get(key[:-len("token_hash")] + "enabled", "true").lower() != "false" and
                    credentials.get(key[:-len("token_hash")] + "identity") and
                    credentials.get(key[:-len("token_hash")] + "role") in {"nms_oss", "vendor_agent", "partner_service", "analytics_tool"}
                    for key, value in credentials.items() if key.endswith(".token_hash"))
        if not valid:
            raise ValueError("REGISTRY_ACCESS_TOKEN has no enabled matching identity in credential file")
    if internal and db == "postgresql":
        required(config, "POSTGRES_PASSWORD")
        services["openan-postgres"] = {"image": images["postgres"], "pull_policy": "never", "restart": "unless-stopped",
                                      "environment": {"POSTGRES_PASSWORD": config["POSTGRES_PASSWORD"],
                                                      **{key: config[key] for key in ("REGISTRY_DB_NAME", "REGISTRY_DB_USERNAME", "REGISTRY_DB_PASSWORD",
                                                                                     "ORCH_DB_NAME", "ORCH_DB_USERNAME", "ORCH_DB_PASSWORD")}},
                                      "command": ["postgres", "-p", config["DB_PORT"] or "5432"],
                                      "volumes": ["postgres-data:/var/lib/postgresql/data", bind(bundle / "compose/init/create-databases.sh", "/docker-entrypoint-initdb.d/create-databases.sh")],
                                      "networks": ["openan"],                                      "healthcheck": {"test": ["CMD", "pg_isready", "-h", "openan-postgres", "-U", "postgres", "-p", config["DB_PORT"] or "5432"],
                                                                              "interval": "5s", "timeout": "5s", "retries": 20}}
    elif internal:
        required(config, "MYSQL_ROOT_PASSWORD")
        port = config["DB_PORT"] or "3306"
        services["openan-mysql"] = {"image": images["mysql"], "pull_policy": "never", "restart": "unless-stopped",
                                    "environment": {"MYSQL_ROOT_PASSWORD": config["MYSQL_ROOT_PASSWORD"],
                                                    **{key: config[key] for key in ("REGISTRY_DB_NAME", "REGISTRY_DB_USERNAME", "REGISTRY_DB_PASSWORD",
                                                                                   "ORCH_DB_NAME", "ORCH_DB_USERNAME", "ORCH_DB_PASSWORD")}},
                                    "command": ["mysqld", "--port=" + port],
                                    "volumes": ["mysql-data:/var/lib/mysql", bind(bundle / "compose/init/create-mysql-databases.sh", "/docker-entrypoint-initdb.d/create-databases.sh")],
                                    "networks": ["openan"], "healthcheck": {"test": ["CMD-SHELL", f'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --protocol=TCP -h openan-mysql -P {port} -u root -e "SELECT 1"'],
                                                                            "interval": "5s", "timeout": "5s", "retries": 40, "start_period": "40s"}}
    public_tls = None
    if boolean(config, "PUBLIC_ENABLE_HTTPS"):
        public_tls = input_path(config, "PUBLIC_TLS_DIR", base, True)
        material(public_tls, ["server.cer", "server_key.pem"], "Public HTTPS")
        volumes.append(bind(public_tls, "/etc/nginx/pki/public"))
    if not portal and not (bundle / "web/index.html").is_file():
        raise ValueError("Bundle web/index.html missing")
    nginx_volumes = volumes + [bind(bundle / "runtime/nginx.conf", "/etc/nginx/nginx.conf")]
    if not portal:
        nginx_volumes.append(bind(bundle / "web", "/usr/share/nginx/html"))
    depends_on = {name: {"condition": "service_healthy"} for name in ("registry-center", "orchestration-center")}
    if portal:
        depends_on["openan-portal"] = {"condition": "service_healthy"}
    services["openan-nginx"] = {"image": images["nginx"], "pull_policy": "never", "restart": "unless-stopped",
                                 "ports": [f"{config['PUBLIC_BIND']}:{config['PUBLIC_PORT']}:{443 if public_tls else 80}"],
                                 "volumes": nginx_volumes,
                                 "depends_on": depends_on,
                                 "healthcheck": {"test": ["CMD", "nginx", "-t"], "interval": "5s", "timeout": "5s", "retries": 12},
                                 "networks": ["openan"]}
    compose = {"name": config["PROJECT_NAME"], "services": services, "networks": {"openan": {"driver": "bridge"}}}
    if internal:
        compose["volumes"] = {"postgres-data" if db == "postgresql" else "mysql-data": {}}
    return compose, nginx_config(bool(public_tls), locations, public_tls, portal)


def write_plan(compose, nginx, bundle):
    runtime = Path(bundle).resolve() / "runtime"
    runtime.mkdir(mode=0o700, exist_ok=True)
    runtime.chmod(0o700)
    for service in ("registry-center", "orchestration-center"):
        for folder in ("data", "log"):
            path = runtime / service / folder
            path.mkdir(parents=True, exist_ok=True)
            if os.name != "nt" and os.geteuid() == 0:
                os.chown(path, 10001, 10001)
    # Compose performs interpolation even in JSON; escape literal dollar text.
    def escape(value):
        if isinstance(value, str):
            return value.replace("$", "$$")
        if isinstance(value, list):
            return [escape(item) for item in value]
        if isinstance(value, dict):
            return {key: escape(item) for key, item in value.items()}
        return value
    for name, content in (("compose.json", json.dumps(escape(compose), indent=2)), ("nginx.conf", nginx)):
        destination = runtime / name
        # Private permissions at creation, not after a world-readable write.
        fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(content + "\n")
        destination.chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--bundle", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--arch", choices=["amd64", "arm64"], required=True)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    try:
        compose, nginx = plan(args.config, args.bundle, args.arch)
        if args.write:
            write_plan(compose, nginx, args.bundle)
        print("Configuration validated" + ("; private runtime/compose.json generated" if args.write else ""))
    except (ValueError, OSError, KeyError, json.JSONDecodeError) as exc:
        print(f"Configuration rejected: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
