#!/usr/bin/env bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# SPDX-License-Identifier: Apache-2.0
# Generate self-signed certificates for the offline Compose evaluation.
# Produces the ./pki/ directory tree expected by config.env TLS_*_DIR keys.
# Production deployments must use enterprise CA material instead.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$SCRIPT_DIR/../pki}"
DAYS="${2:-825}"
KEY_BITS=3072

log() { echo "[gen-certs] $1"; }

command -v openssl >/dev/null || { echo "openssl required" >&2; exit 1; }

mkdir -p "$OUT"
chmod 0700 "$OUT"

gen_ca() {
    local dir="$1" cn="$2"
    if [ -f "$dir/ca.cer" ]; then log "CA exists: $dir/ca.cer"; return 0; fi
    mkdir -p "$dir" && chmod 0700 "$dir"
    openssl req -x509 -newkey "rsa:$KEY_BITS" -sha256 -days "$DAYS" -nodes \
        -subj "/CN=$cn" -keyout "$dir/ca_key.pem" -out "$dir/ca.cer" 2>/dev/null
    chmod 0600 "$dir/ca_key.pem"
    log "CA generated: $dir/ca.cer"
}

gen_leaf() {
    local dir="$1" cn="$2" san_dns="$3" san_ip="$4" outfile="$5" keyfile="$6" ca_dir="$7"
    if [ -f "$dir/$outfile" ]; then log "Leaf exists: $dir/$outfile"; return 0; fi
    mkdir -p "$dir" && chmod 0700 "$dir"
    local san=""
    [ -n "$san_dns" ] && san="DNS:$san_dns"
    [ -n "$san_ip" ] && san="${san:+,}IP:$san_ip"
    cat > "$dir/ext.cnf" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
${san:+subjectAltName=$san}
EOF
    openssl req -new -newkey "rsa:$KEY_BITS" -sha256 -nodes \
        -subj "/CN=$cn" -keyout "$dir/$keyfile" -out "$dir/request.csr" 2>/dev/null
    openssl x509 -req -in "$dir/request.csr" \
        -CA "$ca_dir/ca.cer" -CAkey "$ca_dir/ca_key.pem" \
        -CAcreateserial -days "$DAYS" -sha256 \
        -extfile "$dir/ext.cnf" -out "$dir/$outfile" 2>/dev/null
    rm -f "$dir/request.csr" "$dir/ext.cnf"
    chmod 0600 "$dir/$keyfile" && chmod 0644 "$dir/$outfile"
    cp "$ca_dir/ca.cer" "$dir/trust.cer"
    chmod 0644 "$dir/trust.cer"
    log "Leaf: $dir/$outfile (SAN: ${san:-none})"
}

gen_signing() {
    local dir="$1" cn="$2" ca_dir="$3"
    if [ -f "$dir/sign.cer" ]; then log "Signing exists: $dir/sign.cer"; return 0; fi
    mkdir -p "$dir" && chmod 0700 "$dir"
    cat > "$dir/ext.cnf" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=dataSigning
EOF
    openssl req -new -newkey "rsa:$KEY_BITS" -sha256 -nodes \
        -subj "/CN=$cn" -keyout "$dir/sign_key.pem" -out "$dir/request.csr" 2>/dev/null
    openssl x509 -req -in "$dir/request.csr" \
        -CA "$ca_dir/ca.cer" -CAkey "$ca_dir/ca_key.pem" \
        -CAcreateserial -days "$DAYS" -sha256 \
        -extfile "$dir/ext.cnf" -out "$dir/sign.cer" 2>/dev/null
    rm -f "$dir/request.csr" "$dir/ext.cnf"
    chmod 0600 "$dir/sign_key.pem" && chmod 0644 "$dir/sign.cer"
    # JWS signing key is unencrypted (empty password file)
    : > "$dir/cert_pwd"
    chmod 0600 "$dir/cert_pwd"
    log "Signing: $dir/sign.cer"
}

log "Output: $OUT"

# --- CA ---
gen_ca "$OUT/ca" "OpenAN-Compose-CA"

# --- Public TLS (nginx) ---
gen_leaf "$OUT/public" "openan-compose" "localhost" "127.0.0.1" \
    "server.cer" "server_key.pem" "$OUT/ca"
# Public TLS doesn't need cert_pwd (nginx reads plain key)
rm -f "$OUT/public/cert_pwd" 2>/dev/null || true

# --- Backend TLS (registry-center) ---
gen_leaf "$OUT/registry" "registry-center" "registry-center,localhost" "127.0.0.1" \
    "server.cer" "server_key.pem" "$OUT/ca"
: > "$OUT/registry/cert_pwd"; chmod 0600 "$OUT/registry/cert_pwd"

# --- Backend TLS (orchestration-center) ---
gen_leaf "$OUT/orchestration" "orchestration-center" "orchestration-center,localhost" "127.0.0.1" \
    "server.cer" "server_key.pem" "$OUT/ca"
: > "$OUT/orchestration/cert_pwd"; chmod 0600 "$OUT/orchestration/cert_pwd"

# --- JWS Signing ---
gen_signing "$OUT/signing" "OpenAN-Signing" "$OUT/ca"

log ""
log "Certificate tree generated under: $OUT"
log "config.env references (HTTP evaluation needs none of these):"
echo "  PUBLIC_TLS_DIR=$OUT/public"
echo "  REGISTRY_TLS_DIR=$OUT/registry"
echo "  ORCH_TLS_DIR=$OUT/orchestration"
echo "  REGISTRY_SIGN_DIR=$OUT/signing"
echo "  REGISTRY_PROXY_TLS_DIR=$OUT/public   (trust.cer for backend verification)"
echo "  ORCH_PROXY_TLS_DIR=$OUT/public"
