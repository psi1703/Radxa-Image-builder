# Security notes

- Never commit `build/update-signing/cubie-a5e-update-private.pem` or any copy of it.
- Review `TARGET_DEVICE` with `lsblk` before every image build; the entire selected disk is erased.
- The image's requested initial credentials are `initbox` / `init`. Change this policy before exposing the board to an untrusted network.
- Keep the source pins and donor checksum reviewable. Do not weaken checksum or commit-identity failures to warnings.
