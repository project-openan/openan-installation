# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Regression tests for the gen_certs.py deployment certificate tool."""
import importlib.util
import os
from pathlib import Path
import sys

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.x509.oid import ExtendedKeyUsageOID, ExtensionOID

TOOL = Path(__file__).resolve().parents[1] / "tool/gen_certs.py"


def load_tool():
    spec = importlib.util.spec_from_file_location("gen_certs", TOOL)
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("gen_certs", module)
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def generator():
    module = load_tool()
    return module.StandaloneCertGenerator(), module


PASSWORD = "TestPwd16!a"


def generate_all(gen, tmp_path, **kwargs):
    """Generate CA + one signed leaf, return (ca_dir, leaf_dir)."""
    ca_dir = str(tmp_path / "ca")
    leaf_dir = str(tmp_path / "leaf")
    assert gen.generate_ca(ca_dir, PASSWORD) is True
    assert gen.generate_signed_server_cert(
        leaf_dir, ca_dir, PASSWORD,
        common_name="registry-center",
        san_dns=["registry-center", "registry-center.openan.svc"],
        san_ips=["127.0.0.1"], password=PASSWORD, **kwargs) is True
    return ca_dir, leaf_dir


def load_cert(path):
    with open(path, "rb") as f:
        return x509.load_pem_x509_certificate(f.read())


def load_key(path, password):
    with open(path, "rb") as f:
        return serialization.load_pem_private_key(f.read(), password.encode())


def load_key_from_file(path, password_path):
    with open(password_path) as f:
        password = f.read()
    return load_key(path, password)


def test_ca_is_a_real_ca(generator, tmp_path):
    gen, _ = generator
    ca_dir, _ = generate_all(gen, tmp_path)
    cert = load_cert(os.path.join(ca_dir, "ca.cer"))
    assert cert.public_key().key_size >= 2048
    constraints = cert.extensions.get_extension_for_class(x509.BasicConstraints)
    assert constraints.value.ca is True
    assert constraints.critical is True
    key_usage = cert.extensions.get_extension_for_class(x509.KeyUsage)
    assert key_usage.value.key_cert_sign is True


def test_leaf_is_signed_by_ca_with_san(generator, tmp_path):
    gen, _ = generator
    ca_dir, leaf_dir = generate_all(gen, tmp_path)
    ca_cert = load_cert(os.path.join(ca_dir, "ca.cer"))
    leaf = load_cert(os.path.join(leaf_dir, "server.cer"))
    # issuer points at the CA subject
    assert leaf.issuer == ca_cert.subject
    # AKI matches the CA SKI
    aki = leaf.extensions.get_extension_for_class(x509.AuthorityKeyIdentifier)
    ski = ca_cert.extensions.get_extension_for_class(x509.SubjectKeyIdentifier)
    assert aki.value.key_identifier == ski.value.digest
    # serverAuth EKU, no CA capability
    eku = leaf.extensions.get_extension_for_class(x509.ExtendedKeyUsage)
    assert ExtendedKeyUsageOID.SERVER_AUTH in eku.value
    assert leaf.extensions.get_extension_for_class(x509.BasicConstraints).value.ca is False
    # SAN carries DNS + IP entries
    san = leaf.extensions.get_extension_for_class(x509.SubjectAlternativeName)
    names = san.value.get_values_for_type(x509.DNSName)
    assert "registry-center" in names
    assert str(san.value.get_values_for_type(x509.IPAddress)[0]) == "127.0.0.1"


def test_leaf_key_is_encrypted_pkcs8_with_password(generator, tmp_path):
    gen, _ = generator
    _, leaf_dir = generate_all(gen, tmp_path)
    key_path = os.path.join(leaf_dir, "server_key.pem")
    with open(key_path, "rb") as f:
        pem = f.read()
    assert b"ENCRYPTED" in pem
    key = load_key_from_file(key_path, os.path.join(leaf_dir, "cert_pwd"))
    assert key.key_size >= 2048


def test_ingress_variant_is_plain_pem_without_pwd(generator, tmp_path):
    gen, _ = generator
    _, leaf_dir = generate_all(gen, tmp_path, cert_file="tls.crt",
                               key_file="tls.key")
    key_path = os.path.join(leaf_dir, "tls.key")
    with open(key_path, "rb") as f:
        pem = f.read()
    assert b"ENCRYPTED" not in pem
    with pytest.raises(FileNotFoundError):
        open(os.path.join(leaf_dir, "cert_pwd"))
    x509.load_pem_x509_certificate(
        open(os.path.join(leaf_dir, "tls.crt"), "rb").read())


def test_trust_cer_is_a_copy_of_the_ca(generator, tmp_path):
    gen, _ = generator
    ca_dir, leaf_dir = generate_all(gen, tmp_path)
    trust = load_cert(os.path.join(leaf_dir, "trust.cer"))
    ca = load_cert(os.path.join(ca_dir, "ca.cer"))
    assert trust == ca


def test_idempotent_rerun_skips_existing(generator, tmp_path):
    gen, _ = generator
    ca_dir, leaf_dir = generate_all(gen, tmp_path)
    assert gen.generate_ca(ca_dir, PASSWORD) is False
    assert gen.generate_signed_server_cert(
        leaf_dir, ca_dir, PASSWORD, common_name="registry-center",
        san_dns=["registry-center"], password=PASSWORD) is False


def test_duplicate_extensions_are_impossible(generator, tmp_path):
    gen, _ = generator
    _, leaf_dir = generate_all(gen, tmp_path)
    leaf = load_cert(os.path.join(leaf_dir, "server.cer"))
    oids = [e.oid for e in leaf.extensions]
    # the openEuler openssl CLI bug this tool avoids: no repeated extension
    assert len(oids) == len(set(oids))
