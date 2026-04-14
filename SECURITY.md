# Security Policy

## Contact

Email security issues to **hello@patina.work**. Do not open a public GitHub issue for security problems.

Acknowledge SLA: **72 hours**. If you do not hear back in 72 hours, mail again with `[unack]` in the subject.

## Scope

In scope:

- `patina.work` and all subdomains
- The Cloudflare Pages/Worker code under `site/functions/` in the public repo
- The macOS app binary distributed from `patina.work`
- Public source in `github.com/MariusAure/patina.work`
- Prompt-injection vectors in LLM-bound content — URL entity extraction, `<url>...</url>` fenced rows, window titles, element labels, and anything else that reaches `Analyzer.swift:buildPrompt()` as observation data

Out of scope:

- Third-party services Patina depends on: Together AI, Stripe, Cloudflare. Report those directly to the vendor.
- Vulnerabilities in Apple frameworks (AppKit, ApplicationServices) — report to Apple.
- Denial-of-service via volumetric traffic. Patina runs on a free-tier Cloudflare plan; we accept this risk.
- SPF / DKIM / DMARC findings on `hello@patina.work`.
- Social engineering of the founder or customers.
- Findings that require physical access to an already-compromised Mac.

## Safe harbor

We will not pursue legal action for good-faith security research that:

- Does not access, alter, or destroy data belonging to anyone but you.
- Stays within the scope above.
- Gives us a reasonable chance to fix the issue before public disclosure (we aim for 30 days).
- Does not rely on social engineering, phishing, or physical attacks.

## What we want in a report

- A description of the issue and its impact.
- Steps to reproduce. A proof-of-concept is welcome but not required.
- Your name or handle if you want credit. We will list you here.

## No bounty

Patina is a solo indie project and does not run a paid bug bounty. We will credit researchers publicly and reply with a thank-you — that is the full reward.
