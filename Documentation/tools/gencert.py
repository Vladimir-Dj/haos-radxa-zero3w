"""Generate the self-signed TLS certificate Home Assistant serves on this board.

Run it INSIDE the homeassistant container, which has the cryptography module;
the Home Assistant OS host has no openssl binary at all:

    cat gencert.py | ssh -p 22222 root@<board>         'docker exec -i homeassistant python3 -'

It writes into /config because /ssl is mounted read-only in that container and
docker cp out of it does not work. Move the files into place on the host:

    cd /mnt/data/supervisor/homeassistant
    mv -f _newcert_fullchain.pem /mnt/data/supervisor/ssl/fullchain.pem
    mv -f _newcert_privkey.pem  /mnt/data/supervisor/ssl/privkey.pem
    chmod 644 /mnt/data/supervisor/ssl/fullchain.pem
    chmod 600 /mnt/data/supervisor/ssl/privkey.pem

Then point Home Assistant at them in Settings > System > Network > HTTP server
and restart. Do NOT put this in configuration.yaml - an http: block there is
ignored since the settings were migrated to the UI.

Edit IP_ADDRESSES / DNS_NAMES below for a different board. Modern browsers
reject a certificate that names an IP only in the Common Name, so every address
the board is reached by must appear in the SubjectAlternativeName list.

See Documentation/radxa-zero3w-changes.md, "Outside this repository".
"""
import datetime, ipaddress, os
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa

KEY = '/config/_newcert_privkey.pem'
CRT = '/config/_newcert_fullchain.pem'

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
name = x509.Name([
    x509.NameAttribute(NameOID.COMMON_NAME, 'homeassistant'),
    x509.NameAttribute(NameOID.ORGANIZATION_NAME, 'Home Assistant (Radxa ZERO 3W)'),
])
san = x509.SubjectAlternativeName([
    x509.DNSName('homeassistant.local'),
    x509.DNSName('homeassistant'),
    x509.IPAddress(ipaddress.ip_address('192.168.5.51')),
    x509.IPAddress(ipaddress.ip_address('127.0.0.1')),
])
now = datetime.datetime.now(datetime.timezone.utc)
cert = (x509.CertificateBuilder()
    .subject_name(name).issuer_name(name)
    .public_key(key.public_key())
    .serial_number(x509.random_serial_number())
    .not_valid_before(now - datetime.timedelta(days=1))
    .not_valid_after(now + datetime.timedelta(days=3650))
    .add_extension(san, critical=False)
    .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
    .add_extension(x509.KeyUsage(digital_signature=True, key_encipherment=True,
                                 content_commitment=False, data_encipherment=False,
                                 key_agreement=False, key_cert_sign=False,
                                 crl_sign=False, encipher_only=False, decipher_only=False),
                   critical=True)
    .add_extension(x509.ExtendedKeyUsage([x509.oid.ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
    .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
    .sign(key, hashes.SHA256()))

with open(KEY, 'wb') as f:
    f.write(key.private_bytes(serialization.Encoding.PEM,
                              serialization.PrivateFormat.TraditionalOpenSSL,
                              serialization.NoEncryption()))
os.chmod(KEY, 0o600)
with open(CRT, 'wb') as f:
    f.write(cert.public_bytes(serialization.Encoding.PEM))
os.chmod(CRT, 0o644)

# read back what was actually written
rd = x509.load_pem_x509_certificate(open(CRT, 'rb').read())
print('subject   :', rd.subject.rfc4514_string())
print('issuer    :', rd.issuer.rfc4514_string())
print('serial    :', rd.serial_number)
print('not before:', rd.not_valid_before_utc)
print('not after :', rd.not_valid_after_utc)
print('SAN       :', [str(g.value) for g in rd.extensions.get_extension_for_class(x509.SubjectAlternativeName).value])
print('key size  :', rd.public_key().key_size)
print('sig alg   :', rd.signature_hash_algorithm.name)
