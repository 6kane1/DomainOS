#!/bin/sh
# Signs Domain OS update feeds with a private update key: update/stable.json and update/test.bin (read by the C#
# Toolbox 1.16.x), update/stable-native.json and update/test-native.bin (the native Toolbox 1.17.0+). Writes <file>.sig
# and <file>.signed (signature line + feed in one file, read by Toolbox 1.16.1 Test 4 and newer)
# (base64 DER ECDSA P-256 over SHA-256, the format every Toolbox version reads; no key id inside, Toolbox tries each
# key it trusts). After signing, each .sig is checked against the key's public half, so a bad signature never ships.
#
# Usage:  sign-feed.sh [--backup] FILE...
#   default         main key    ~/.config/domainos/update-signing-key.pem         (or $DOMAINOS_SIGNING_KEY)
#   --backup        backup key  ~/.config/domainos/update-signing-key-backup.pem  (or $DOMAINOS_SIGNING_KEY_BACKUP)
#   DOMAINOS_SIGN_WITH=backup   same as --backup (for callers such as publish-test-build.py that pass only files)
#
# Keys (Updater::trusted_keys in ToolboxNative core/src/system/updater.rs, the same as Updater.TrustedKeys of the C#
# Updater.cs; key id = first 16 hex of SHA-256 of the public key DER):
#   main    824da223f01c0905  stays on the author's PC (back it up offline too)
#   backup  a807a74083942dde  belongs OFFLINE (USB stick / paper); copy it here only for an emergency signing, then delete
#   Fingerprint of a key:  openssl pkey -in KEY.pem -pubout -outform DER | sha256sum | cut -c1-16
# Never commit, upload, print or log a private key.
#
# ROTATION (main key leaked or lost):
#   1. Leaked: stop using the main key at once. Lost: nothing to revoke, but treat it the same way.
#   2. Make a new key pair (openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out NEW.pem;
#      chmod 600). Put its public key (openssl pkey -in NEW.pem -pubout -outform DER | base64 -w0) into ToolboxNative core/src/system/updater.rs (PUBLIC_KEY, BACKUP_PUBLIC_KEY):
#      the old backup becomes PublicKey (main), the new key becomes BackupPublicKey, the TrustedKeys ids are updated
#      (the key-list test in updater.rs checks them), and a leaked key's id goes into REVOKED_KEY_IDS.
#   3. Build that Toolbox, bring the backup private key from offline storage, and sign the feed that ships it:
#        DOMAINOS_SIGNING_KEY_BACKUP=/media/usb/update-signing-key-backup.pem sign-feed.sh --backup update/stable.json
#      Installed Toolbox versions already trust the backup key, so they accept this feed and update.
#   4. From then on the old backup is the main key: move it to ~/.config/domainos/update-signing-key.pem (or keep it on
#      the stick and pass DOMAINOS_SIGNING_KEY), keep NEW.pem offline as the next backup, delete every copy of the
#      compromised key. Re-sign the test feed (test.bin) with the same key.
#   If the backup key is lost or leaked while the main key is fine: ship a Toolbox with a new BackupPublicKey (and the
#   old backup id in RevokedKeyIds if it leaked), signed with the main key as usual.
set -e
WHICH="${DOMAINOS_SIGN_WITH:-main}"
if [ "$1" = "--backup" ]; then WHICH=backup; shift; fi
case "$WHICH" in
  main)   KEY="${DOMAINOS_SIGNING_KEY:-$HOME/.config/domainos/update-signing-key.pem}" ;;
  backup) KEY="${DOMAINOS_SIGNING_KEY_BACKUP:-$HOME/.config/domainos/update-signing-key-backup.pem}" ;;
  *) echo "DOMAINOS_SIGN_WITH must be main or backup" >&2; exit 2 ;;
esac
[ -r "$KEY" ] || { echo "no $WHICH signing key at $KEY" >&2; exit 1; }
[ $# -gt 0 ] || { echo "usage: sign-feed.sh [--backup] FILE..." >&2; exit 2; }
PUB="$(mktemp)"; SIG="$(mktemp)"
trap 'rm -f "$PUB" "$SIG"' EXIT
openssl pkey -in "$KEY" -pubout -out "$PUB"
ID="$(openssl pkey -pubin -in "$PUB" -outform DER | sha256sum | cut -c1-16)"
for f in "$@"; do
  openssl dgst -sha256 -sign "$KEY" -out "$SIG" "$f"
  openssl dgst -sha256 -verify "$PUB" -signature "$SIG" "$f" >/dev/null
  base64 -w0 "$SIG" > "$f.sig"
  # Toolbox 1.16.1 Test 4+: signature and feed in one file (the site cache can never pair a feed with an old .sig).
  { cat "$f.sig"; printf '\n'; cat "$f"; } > "$f.signed"
  echo "signed $f ($WHICH key $ID)"
done
