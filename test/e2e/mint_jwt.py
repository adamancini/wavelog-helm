#!/usr/bin/env python3
"""Test-only identity provider for the sso e2e scenario.

  mint_jwt.py keys <dir>          write <dir>/{idp.pem,other.pem,jwks.json};
                                  the JWKS publishes only idp.pem's public key
  mint_jwt.py token <pem> <iss> <sub>
                                  print an RS256 access token signed by <pem>

Both keys use the same kid, so a token signed by other.pem selects the
published key and must fail signature verification.
"""
import json
import sys
import time
from pathlib import Path

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

KID = "e2e"


def new_key(path: Path) -> rsa.RSAPrivateKey:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    return key


def keys(out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    idp = new_key(out / "idp.pem")
    new_key(out / "other.pem")
    jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(idp.public_key()))
    jwk.update({"kid": KID, "use": "sig", "alg": "RS256"})
    (out / "jwks.json").write_text(json.dumps({"keys": [jwk]}))


def token(pem: Path, iss: str, sub: str) -> None:
    now = int(time.time())
    claims = {
        "iss": iss,
        "sub": sub,
        # Wavelog overwrites mapped user fields on every login, so these
        # match the install admin.
        "preferred_username": "admin",
        "email": "admin@example.com",
        "callsign": "N0CALL",
        "typ": "Bearer",
        "iat": now,
        "nbf": now - 60,
        # Expiring exactly now would be rejected; allow time for the request.
        "exp": now + 300,
    }
    print(jwt.encode(claims, pem.read_bytes(), algorithm="RS256", headers={"kid": KID}))


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "keys":
        keys(Path(argv[2]))
    elif len(argv) == 5 and argv[1] == "token":
        token(Path(argv[2]), argv[3], argv[4])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
