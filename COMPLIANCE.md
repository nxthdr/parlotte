# Export Compliance

This document records Parlotte's U.S. encryption export-compliance position
and the reasoning behind the `ITSAppUsesNonExemptEncryption` value in the app's
`Info.plist`. It is informational, not legal advice; if you need certainty,
have it reviewed by someone versed in the EAR.

## Summary

| Item | Value |
|---|---|
| `ITSAppUsesNonExemptEncryption` | `false` (set in `apple/Parlotte/project.yml`) |
| Basis | Encryption is **exempt** — standard, published algorithms in a mass-market, open-source app |
| Suggested ECCN | `5D992.c` (mass-market encryption software) |
| Source code | Publicly available, MIT-licensed: <https://github.com/nxthdr/parlotte> |

## What encryption Parlotte uses

Parlotte does not implement any proprietary or non-standard cryptography. All
encryption comes from the Matrix end-to-end-encryption stack (Olm/Megolm) as
provided by `matrix-rust-sdk` (`matrix-sdk-crypto`), built on standard,
published primitives:

- **Curve25519** — key agreement (X25519) and Ed25519 signing
- **AES-256** (CBC/CTR) — message payload encryption
- **HMAC-SHA-256** — message authentication
- **PBKDF2 / HKDF** — key derivation for secure storage and backup

Transport security additionally uses the operating system's TLS/HTTPS via
standard networking APIs.

## Why `ITSAppUsesNonExemptEncryption = false`

Apple's guidance
(<https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations>)
says to set the key to `NO` when the app "only uses forms of encryption that
are exempt from export compliance documentation requirements."

Parlotte's encryption qualifies as exempt under EAR Category 5, Part 2:

- It uses only **standard, published** algorithms (no proprietary crypto).
- It is a **mass-market** software product distributed through the App Store.
- Its **source code is publicly available** (MIT, public GitHub repo).

Because the build declares exemption directly in `Info.plist`, App Store
Connect auto-marks each build compliant — there is no per-build encryption
questionnaire and no export-documentation upload (including the France-
distribution document prompt, which only appears on the non-exempt path).

## Associated obligation: annual self-classification report

Per Apple's documentation, apps using **exempt** encryption "might
alternatively be required to submit a year-end self-classification report to
the U.S. government." This is an **annual** filing — it does **not** gate
TestFlight or App Store submission, and there is nothing to file before
shipping.

The report is submitted once per year (covering the prior calendar year,
due by **February 1**) by email to BIS and the NSA. Template:

```
To: crypt-supp8@bis.doc.gov, enc@nsa.gov
Subject: Annual Self-Classification Report — NXTHDR

Per EAR §740.17(e)(3), the following mass-market encryption product is
self-classified for the reporting period [YEAR]:

  Manufacturer:   NXTHDR
  Product name:   Parlotte (macOS Matrix client)
  ECCN:           5D992.c
  Encryption:     Standard published algorithms only — Curve25519/Ed25519,
                  AES-256, HMAC-SHA-256, PBKDF2/HKDF — via the Matrix
                  Olm/Megolm protocols (matrix-rust-sdk). No proprietary
                  cryptography.
  Source code:    https://github.com/nxthdr/parlotte (MIT)
  Contact:        <name> <email>
```

(BIS also accepts the report as a CSV attachment in the format described at
<https://www.bis.doc.gov/index.php/policy-guidance/encryption/4-reports-and-reviews/a-annual-self-classification>.)

## France distribution

France applies a light declaration regime to standard/mass-market
cryptography. App Store Connect does not require a separate French encryption
document upload once the build declares exemption (`false`). If a formal ANSSI
declaration is ever desired, it is a separate filing from the App Store flow.

## Maintenance

If Parlotte ever adds **non-standard / proprietary** encryption, this position
no longer holds: `ITSAppUsesNonExemptEncryption` would need to become `true`
and Apple's documentation-upload path (or a CCATS/ERN) would apply. Revisit
this file whenever the crypto stack changes.
