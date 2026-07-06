# Aperture — Marketing Website

The public marketing site for **Aperture**, a non‑custodial, open‑source
cryptocurrency wallet for iPhone. Design and copy are grounded directly in the
app's source code (`github.com/devdasx/aperture`) — every claim on the site
maps to something real in the product.

**Art direction:** Apple‑style restraint — monochrome (ink `#0B0D11` on white
`#F5F5F7`), SF‑system type at large scale with tight tracking, generous white
space, ruled "spec‑sheet" grids, and quiet motion. Light mode throughout.

---

## Pages

Open `index.html` (it redirects to the landing screen), or open any screen
file directly in a browser.

| # | File | Screen | What it covers |
|---|------|--------|----------------|
| 1 | `Aperture Landing.dc.html` | **Overview** | Hero landing — app icon bloom, headline, download CTAs, quiet facts row, footer |
| 2 | `Aperture Security.dc.html` | **Security** | Secure Enclave key generation, AES‑GCM‑256 at rest, Face ID + hashed PIN, leaked‑seed screening, delete‑means‑delete, encrypted iCloud backup |
| 3 | `Aperture Privacy.dc.html` | **Privacy Policy** | Full dated policy — "data collected: none", on‑device storage, permissions, third‑party infrastructure exposure, GDPR/CCPA, children/age |
| 4 | `Aperture Terms.dc.html` | **Terms of Use** | 17‑section legal document — self‑custody responsibility, no recovery/reversal, disclaimers, liability, governing law |
| 5 | `Aperture Open Source.dc.html` | **Open Source** | Reproducible builds (clone → build → compare), two‑dependency discipline, Swift 6, public test suite |
| 6 | `Aperture Contact.dc.html` | **Contact** | Channels (email, GitHub issues, security disclosures) + a form that composes an email via the visitor's own mail app |
| 7 | `Aperture FAQ.dc.html` | **FAQ** | 24 grounded Q&As across Getting started / Keys & security / Privacy / Sending & receiving / Verification & trust |

**Navigation:** each page has a top bar (app icon + wordmark, Download button).
Full navigation lives in the footer, trimmed to **Overview · Security · Open
Source** on every screen.

---

## Folder structure

```
Aperture Website/
├─ index.html                     # entry point → redirects to the landing screen
├─ README.md                      # this file
├─ support.js                     # runtime that renders the .dc.html screens
├─ Aperture Landing.dc.html
├─ Aperture Security.dc.html
├─ Aperture Privacy.dc.html
├─ Aperture Terms.dc.html
├─ Aperture Open Source.dc.html
├─ Aperture Contact.dc.html
├─ Aperture FAQ.dc.html
└─ assets/
   ├─ icon-1024.png              # Aperture app icon (squircle tile) — nav + hero + footer
   └─ mark-white.svg             # Aperture iris mark (white) — dark closing sections
```

---

## Running it

No build step, no server, no dependencies to install — it runs entirely in the
browser, offline.

- **Locally:** open `index.html` (or any screen file) in a modern browser.
- **Hosting:** upload the whole folder to any static host. `index.html` is the
  entry point. Note that screen filenames contain spaces, so links reference
  them URL‑encoded (e.g. `Aperture%20Landing.dc.html`).

Each `.dc.html` screen is a self‑contained document that loads the local
`support.js` runtime and paints itself — there is no bundler and nothing is
fetched from a CDN.

---

## Design system

- **Colors:** Aperture Black `#0B0D11` · Cloud `#F5F5F7` · Pure White `#FFFFFF`.
  Text tints are ink/cloud at reduced opacity. Monochrome by conviction — no
  accent color is used on the site.
- **Type:** self-hosted Inter, loaded from `assets/fonts/inter-latin.woff2`,
  with semibold headings, negative tracking, and regular body copy.
- **Motion:** a single bloom on the hero icon, gentle staggered rise for hero
  text, and slow fades — nothing decorative.

---

## Notes

- **App Store:** every "Download" / "Download on the App Store" button links to
  the live listing `https://apps.apple.com/app/id6780187283`.
- `support@aperturex.io` on the Contact page is a **placeholder** — replace it
  with the real support address before publishing.
- All product claims (24 networks, Secure Enclave, reproducible build, 600,000
  PBKDF2 iterations, leaked‑seed blocklist, fresh‑install keychain wipe, etc.)
  are drawn from the Aperture app source and are current as of the app version
  referenced on the legal pages.
- Brand assets © Aperture, from the project's brand kit.
