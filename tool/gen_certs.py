# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# SPDX-License-Identifier: Apache-2.0
"""OpenAN deployment certificate tooling (standalone, no registry-center source needed).

Generates a CA hierarchy + per-component leaf certificates for the
containerized deployment:

1. A CA:TRUE root so one trust anchor can verify every service leaf
   (ingress proxy-ssl-verify, frontend backendTls, OC->RC registry client
   all share trust.cer).
2. SAN support: leaf certificates carry service DNS names and optional
   IPs, required by ingress SNI checks and by browsers accessing the
   ingress directly by IP.

Uses the cryptography library's structured builder (one add_extension per
extension), which cannot produce the duplicate-extension certificates that
openEuler's openssl CLI req -x509 + -addext produces (RFC 5280 violation,
rejected by strict validators like Python ssl).

Usage:
    python3 gen_certs.py --out /path/to/certs [--namespace openan] \
        [--ingress-host openan.test] [--ingress-ip 192.168.200.137] [...]

Output tree (compatible with the chart TLS secret contract):
    <out>/ca/{ca.cer, ca_key.pem, cert_pwd}
    <out>/registry-center/{server.cer, server_key.pem, cert_pwd, trust.cer}
    <out>/orchestration-center/{server.cer, server_key.pem, cert_pwd, trust.cer}
    <out>/ingress/{tls.crt, tls.key, cert_pwd, trust.cer}
"""
import argparse
import os
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
import datetime
import ipaddress


class StandaloneCertGenerator:
    """Standalone certificate generator (no registry-center dependency)."""

    CA_DAYS = 3650
    LEAF_DAYS = 825

    def __init__(self, key_algorithm="RSA"):
        self.key_algorithm = key_algorithm

    def _generate_key(self):
        from cryptography.hazmat.primitives.asymmetric import rsa
        return rsa.generate_private_key(public_exponent=65537, key_size=2048)

    def _exists_any(self, directory, names):
        return any(os.path.exists(os.path.join(directory, n)) for n in names)

    def _write_cert(self, directory, filename, cert):
        path = os.path.join(directory, filename)
        with open(path, "wb") as f:
            f.write(cert.public_bytes(serialization.Encoding.PEM))
        os.chmod(path, 0o644)

    def _write_encrypted_key(self, directory, filename, key, password):
        path = os.path.join(directory, filename)
        with open(path, "wb") as f:
            f.write(key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.PKCS8,
                encryption_algorithm=serialization.BestAvailableEncryption(
                    password.encode())))
        os.chmod(path, 0o600)

    # --- CA ---
    def generate_ca(self, ca_dir, password):
        """Generate CA:TRUE root certificate (ca.cer / ca_key.pem / cert_pwd)."""
        if self._exists_any(ca_dir, ["ca.cer", "ca_key.pem"]):
            return False
        os.makedirs(ca_dir, mode=0o700, exist_ok=True)
        key = self._generate_key()
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "OpenAN-CA")])
        builder = (x509.CertificateBuilder()
                   .subject_name(name).issuer_name(name)
                   .not_valid_before(datetime.datetime.now(datetime.timezone.utc))
                   .not_valid_after(datetime.datetime.now(datetime.timezone.utc)
                                    + datetime.timedelta(days=self.CA_DAYS))
                   .serial_number(x509.random_serial_number())
                   .public_key(key.public_key()))
        builder = builder.add_extension(
            x509.BasicConstraints(ca=True, path_length=None), critical=True)
        builder = builder.add_extension(
            x509.KeyUsage(digital_signature=False, content_commitment=False,
                          key_encipherment=False, data_encipherment=False,
                          key_agreement=False, key_cert_sign=True,
                          crl_sign=True, encipher_only=False, decipher_only=False),
            critical=True)
        builder = builder.add_extension(
            x509.SubjectKeyIdentifier.from_public_key(key.public_key()),
            critical=False)
        cert = builder.sign(key, hashes.SHA256())
        self._write_cert(ca_dir, "ca.cer", cert)
        self._write_encrypted_key(ca_dir, "ca_key.pem", key, password)
        with open(os.path.join(ca_dir, "cert_pwd"), "w") as f:
            f.write(password)
        os.chmod(os.path.join(ca_dir, "cert_pwd"), 0o600)
        return True

    # --- leaf signed by CA, with SAN ---
    def load_ca(self, ca_dir, password):
        """Load CA cert object and private key from ca_dir."""
        with open(os.path.join(ca_dir, "ca.cer"), "rb") as f:
            ca_cert = x509.load_pem_x509_certificate(f.read())
        with open(os.path.join(ca_dir, "ca_key.pem"), "rb") as f:
            ca_key = serialization.load_pem_private_key(f.read(), password.encode())
        return ca_cert, ca_key

    def generate_signed_server_cert(self, cert_dir, ca_dir, ca_password,
                                    common_name, san_dns=(), san_ips=(),
                                    password=None,
                                    cert_file=None,
                                    key_file=None):
        """Generate a server leaf signed by the CA, with SAN.

        cert_file/key_file default to upstream contract names (server.cer /
        server_key.pem); ingress uses tls.crt / tls.key.
        """
        if self._exists_any(cert_dir, [cert_file or "server.cer",
                                       key_file or "server_key.pem"]):
            return False
        os.makedirs(cert_dir, mode=0o700, exist_ok=True)
        ca_cert, ca_key = self.load_ca(ca_dir, ca_password)

        key = self._generate_key()
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)])
        builder = (x509.CertificateBuilder()
                   .subject_name(subject)
                   .issuer_name(ca_cert.subject)
                   .not_valid_before(datetime.datetime.now(datetime.timezone.utc))
                   .not_valid_after(datetime.datetime.now(datetime.timezone.utc)
                                    + datetime.timedelta(days=self.LEAF_DAYS))
                   .serial_number(x509.random_serial_number())
                   .public_key(key.public_key()))
        builder = builder.add_extension(
            x509.BasicConstraints(ca=False, path_length=None), critical=True)
        builder = builder.add_extension(
            x509.KeyUsage(digital_signature=True, content_commitment=False,
                          key_encipherment=True, data_encipherment=False,
                          key_agreement=False, key_cert_sign=False,
                          crl_sign=False, encipher_only=False, decipher_only=False),
            critical=True)
        builder = builder.add_extension(
            x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
        builder = builder.add_extension(
            x509.SubjectKeyIdentifier.from_public_key(key.public_key()),
            critical=False)
        builder = builder.add_extension(
            x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()),
            critical=False)
        san = [x509.DNSName(d) for d in san_dns]
        san += [x509.IPAddress(ipaddress.ip_address(i)) for i in san_ips]
        if san:
            builder = builder.add_extension(x509.SubjectAlternativeName(san),
                                            critical=False)
        cert = builder.sign(ca_key, hashes.SHA256())

        self._write_cert(cert_dir, cert_file or "server.cer", cert)
        self._write_encrypted_key(cert_dir, key_file or "server_key.pem", key,
                                  password or ca_password)
        if cert_file == "tls.crt" or key_file == "tls.key":
            # ingress key must be readable by nginx: plain PEM
            plain = key.private_bytes(encoding=serialization.Encoding.PEM,
                                      format=serialization.PrivateFormat.PKCS8,
                                      encryption_algorithm=serialization.NoEncryption())
            with open(os.path.join(cert_dir, key_file or "tls.key"), "wb") as f:
                f.write(plain)
            os.chmod(os.path.join(cert_dir, key_file or "tls.key"), 0o600)
        # password file for app-consumed keys (not for ingress tls.key)
        if not (cert_file == "tls.crt" or key_file == "tls.key"):
            with open(os.path.join(cert_dir, "cert_pwd"), "w") as f:
                f.write(password or ca_password)
            os.chmod(os.path.join(cert_dir, "cert_pwd"), 0o600)
        # trust anchor copy
        with open(os.path.join(ca_dir, "ca.cer"), "rb") as f:
            ca_pem = f.read()
        with open(os.path.join(cert_dir, "trust.cer"), "wb") as f:
            f.write(ca_pem)
        return True


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Generate CA + RC/OC/ingress certificates "
                    "for the OpenAN containerized deployment.")
    parser.add_argument("--out", required=True, help="output directory")
    parser.add_argument("--namespace", default="openan")
    parser.add_argument("--cluster-domain", default="cluster.local")
    parser.add_argument("--ingress-host", default="openan.test",
                        help="DNS host for the ingress certificate SAN")
    parser.add_argument("--ingress-ip", action="append", default=[],
                        help="ingress IP for SAN (repeatable)")
    parser.add_argument("--node-ips", action="append", default=[],
                        help="extra node IPs for ingress SAN (repeatable)")
    parser.add_argument("--ca-password", default=None,
                        help="CA/leaf key password; generated if omitted")
    args = parser.parse_args(argv)

    import secrets as _secrets
    password = args.ca_password or _secrets.token_urlsafe(16)

    gen = StandaloneCertGenerator(key_algorithm="RSA")

    ns, dom = args.namespace, args.cluster_domain
    out = args.out

    services = {
        "registry-center": {
            "dns": ["registry-center", f"registry-center.{ns}",
                    f"registry-center.{ns}.svc", f"registry-center.{ns}.svc.{dom}",
                    "localhost"],
            "ips": ["127.0.0.1"],
        },
        "orchestration-center": {
            "dns": ["orchestration-center", f"orchestration-center.{ns}",
                    f"orchestration-center.{ns}.svc",
                    f"orchestration-center.{ns}.svc.{dom}", "localhost"],
            "ips": ["127.0.0.1"],
        },
    }

    ok = gen.generate_ca(os.path.join(out, "ca"), password)
    print(f"CA: {'generated' if ok else 'SKIPPED (exists)'} at {out}/ca")

    for svc, spec in services.items():
        ok = gen.generate_signed_server_cert(
            os.path.join(out, svc), os.path.join(out, "ca"), password,
            common_name=svc, san_dns=spec["dns"], san_ips=spec["ips"],
            password=password)
        print(f"{svc}: {'generated' if ok else 'SKIPPED (exists)'}")

    ingress_dns = [args.ingress_host, "openan.local", "registry.openan.local",
                   "orchestrate.openan.local", "workflow.openan.local"]
    ingress_ips = list(args.ingress_ip) + list(args.node_ips)
    ok = gen.generate_signed_server_cert(
        os.path.join(out, "ingress"), os.path.join(out, "ca"), password,
        common_name=args.ingress_host, san_dns=ingress_dns,
        san_ips=ingress_ips, password=password,
        cert_file="tls.crt", key_file="tls.key")
    print(f"ingress: {'generated' if ok else 'SKIPPED (exists)'}")

    print("\nAll certificates generated under:", out)
    print("Next: create TLS secrets, see QUICKSTART 'HTTPS' section.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
