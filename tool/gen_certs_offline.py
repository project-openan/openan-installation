#!/usr/bin/env python3
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Offline port of the online-install certificate tool, driven by openssl CLI.

The online tool (tool/gen_certs.py) uses the Python cryptography library; an
air-gapped offline host may not have third-party wheels. This port keeps the
same CLI surface and output-tree contract but drives the openssl binary
(present on every supported Linux host), mirroring the recipe proven
end-to-end by tests/offline_compose_container_smoke.py.

Extension data is passed through config files (-config / -extfile), never
through `req -addext`, avoiding the duplicate-extension certificates some
openssl builds produce with -addext (RFC 5280 violation, rejected by strict
validators such as Python ssl).

Usage:
    python3 tool/gen_certs.py --out /root/openan-certs [--namespace openan] \
        [--ingress-host openan.test] [--ingress-ip 192.168.200.137] [...]

Output tree (chart TLS secret contract):
    <out>/ca/{ca.cer, ca_key.pem, cert_pwd}
    <out>/registry-center/{server.cer, server_key.pem, cert_pwd, trust.cer}
    <out>/orchestration-center/{server.cer, server_key.pem, cert_pwd, trust.cer}
    <out>/ingress/{tls.crt, tls.key, trust.cer}          # public server cert; tls.key PLAIN
    <out>/ingress-client/{tls.crt, tls.key, trust.cer}   # ingress->backend client cert; PLAIN key

Existing files are never overwritten (re-runs skip, like the online tool).
"""
import argparse
import os
import secrets
import subprocess
import sys

CA_DAYS = "3650"
LEAF_DAYS = "825"
KEY_BITS = "3072"


def run(*args, password=None):
    env = dict(os.environ)
    if password is not None:
        # Passwords travel via the environment, never via argv (special
        # characters must not break openssl pass: phrases or leak in ps).
        env["OAN_CERT_PASS"] = password
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, env=env)


PASSOUT = ("-passout", "env:OAN_CERT_PASS")
PASSIN = ("-passin", "env:OAN_CERT_PASS")


def write_private(path, data):
    with open(path, "wb") as stream:
        stream.write(data)
    os.chmod(path, 0o600)


def exists_any(directory, names):
    return any(os.path.exists(os.path.join(directory, name)) for name in names)


def generate_ca(ca_dir, password):
    """CA:TRUE root; encrypted key (ca_key.pem), ca.cer, cert_pwd."""
    if exists_any(ca_dir, ("ca.cer", "ca_key.pem")):
        return False
    os.makedirs(ca_dir, mode=0o700, exist_ok=True)
    config = os.path.join(ca_dir, "ca.cnf")
    with open(config, "w") as stream:
        stream.write("[req]\nprompt = no\ndistinguished_name = dn\nx509_extensions = v3_ca\n"
                     "[dn]\nCN = OpenAN-CA\n"
                     "[v3_ca]\nbasicConstraints = critical,CA:TRUE\n"
                     "keyUsage = critical,keyCertSign,cRLSign\n"
                     "subjectKeyIdentifier = hash\n")
    run("openssl", "req", "-x509", "-newkey", f"rsa:{KEY_BITS}", "-sha256",
        "-days", CA_DAYS, "-config", config, *PASSOUT,
        "-keyout", os.path.join(ca_dir, "ca_key.pem"),
        "-out", os.path.join(ca_dir, "ca.cer"), password=password)
    os.chmod(os.path.join(ca_dir, "ca.cer"), 0o644)
    with open(os.path.join(ca_dir, "cert_pwd"), "w") as stream:
        stream.write(password)
    os.chmod(os.path.join(ca_dir, "cert_pwd"), 0o600)
    os.unlink(config)
    return True


def generate_leaf(cert_dir, ca_dir, ca_password, common_name, san_dns, san_ips,
                  password, cert_file, key_file, client_auth=False):
    """Leaf signed by the CA with SAN; app keys encrypted, ingress keys plain."""
    if exists_any(cert_dir, (cert_file, key_file)):
        return False
    os.makedirs(cert_dir, mode=0o700, exist_ok=True)
    csr = os.path.join(cert_dir, "request.csr")
    config = os.path.join(cert_dir, "leaf.cnf")
    plain = cert_file == "tls.crt"  # nginx must read ingress keys without a password
    if plain:
        key_args = ["-nodes"]
        key_password = None
    else:
        key_args = list(PASSOUT)
        key_password = password
    with open(config, "w") as stream:
        stream.write("[req]\nprompt = no\ndistinguished_name = dn\nreq_extensions = v3_req\n"
                     f"[dn]\nCN = {common_name}\n"
                     "[v3_req]\nbasicConstraints = critical,CA:FALSE\n"
                     "keyUsage = critical,digitalSignature,keyEncipherment\n"
                     f"extendedKeyUsage = {'clientAuth' if client_auth else 'serverAuth'}\n")
        if san_dns or san_ips:
            san = ",".join([f"DNS:{name}" for name in san_dns]
                           + [f"IP:{ip}" for ip in san_ips])
            stream.write(f"subjectAltName = {san}\n")
    run("openssl", "req", "-new", "-newkey", f"rsa:{KEY_BITS}", "-sha256",
        "-config", config, *key_args,
        "-keyout", os.path.join(cert_dir, key_file),
        "-out", csr, password=key_password)
    # x509 -req ignores req_extensions; apply them via -extfile (same file).
    run("openssl", "x509", "-req", "-in", csr,
        "-CA", os.path.join(ca_dir, "ca.cer"),
        "-CAkey", os.path.join(ca_dir, "ca_key.pem"),
        *PASSIN,
        "-CAcreateserial", "-days", LEAF_DAYS, "-sha256",
        "-extfile", config, "-extensions", "v3_req",
        "-out", os.path.join(cert_dir, cert_file), password=ca_password)
    os.chmod(os.path.join(cert_dir, cert_file), 0o644)
    os.chmod(os.path.join(cert_dir, key_file), 0o600)
    with open(os.path.join(ca_dir, "ca.cer"), "rb") as src, \
            open(os.path.join(cert_dir, "trust.cer"), "wb") as dst:
        dst.write(src.read())
    os.chmod(os.path.join(cert_dir, "trust.cer"), 0o644)
    if not plain:
        with open(os.path.join(cert_dir, "cert_pwd"), "w") as stream:
            stream.write(password)
        os.chmod(os.path.join(cert_dir, "cert_pwd"), 0o600)
    os.unlink(csr)
    os.unlink(config)
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Generate CA + RC/OC/ingress certificates (openssl CLI) "
                    "for the OpenAN offline Kubernetes deployment.")
    parser.add_argument("--out", required=True, help="output directory")
    parser.add_argument("--namespace", default="openan")
    parser.add_argument("--cluster-domain", default="cluster.local")
    parser.add_argument("--ingress-host", default="openan.test",
                        help="DNS host for the public ingress certificate SAN")
    parser.add_argument("--ingress-ip", action="append", default=[],
                        help="ingress IP for SAN (repeatable)")
    parser.add_argument("--node-ips", action="append", default=[],
                        help="extra node IPs for ingress SAN (repeatable)")
    parser.add_argument("--ca-password", default=None,
                        help="CA/leaf key password; generated if omitted")
    args = parser.parse_args(argv)

    if subprocess.run(["openssl", "version"], stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL).returncode != 0:
        sys.exit("ERROR: openssl not found on PATH")

    password = args.ca_password or secrets.token_urlsafe(16)
    out = args.out
    ns, dom = args.namespace, args.cluster_domain

    services = {
        "registry-center": ["registry-center", f"registry-center.{ns}",
                            f"registry-center.{ns}.svc",
                            f"registry-center.{ns}.svc.{dom}", "localhost"],
        "orchestration-center": ["orchestration-center", f"orchestration-center.{ns}",
                                 f"orchestration-center.{ns}.svc",
                                 f"orchestration-center.{ns}.svc.{dom}", "localhost"],
    }

    ok = generate_ca(os.path.join(out, "ca"), password)
    print(f"CA: {'generated' if ok else 'SKIPPED (exists)'} at {out}/ca")

    for svc, dns in services.items():
        ok = generate_leaf(os.path.join(out, svc), os.path.join(out, "ca"),
                           password, common_name=svc, san_dns=dns,
                           san_ips=["127.0.0.1"], password=password,
                           cert_file="server.cer", key_file="server_key.pem")
        print(f"{svc}: {'generated' if ok else 'SKIPPED (exists)'}")

    ingress_dns = [args.ingress_host, "openan.local", "registry.openan.local",
                   "orchestrate.openan.local", "workflow.openan.local"]
    ingress_ips = list(args.ingress_ip) + list(args.node_ips)
    ok = generate_leaf(os.path.join(out, "ingress"), os.path.join(out, "ca"),
                       password, common_name=args.ingress_host,
                       san_dns=ingress_dns, san_ips=ingress_ips,
                       password=password,
                       cert_file="tls.crt", key_file="tls.key")
    print(f"ingress (public server cert): {'generated' if ok else 'SKIPPED (exists)'}")

    ok = generate_leaf(os.path.join(out, "ingress-client"), os.path.join(out, "ca"),
                       password, common_name="openan-ingress-client",
                       san_dns=[], san_ips=[], password=password,
                       cert_file="tls.crt", key_file="tls.key", client_auth=True)
    print(f"ingress-client (upstream verify/mTLS): {'generated' if ok else 'SKIPPED (exists)'}")

    print("\nAll certificates generated under:", out)
    print("Next: install.sh creates the TLS Secrets and enables ingress "
          "backend verification automatically.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
