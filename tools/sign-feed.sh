#!/bin/sh
# Signs Domain OS update feeds (update/*.json) with the private update key: writes <file>.sig (base64 DER ECDSA P-256,
# SHA-256). The key never leaves this PC: ~/.config/domainos/update-signing-key.pem (back it up offline!).
set -e
KEY="${DOMAINOS_SIGNING_KEY:-$HOME/.config/domainos/update-signing-key.pem}"
for f in "$@"; do
  openssl dgst -sha256 -sign "$KEY" "$f" | base64 -w0 > "$f.sig"
  echo "signed $f"
done
