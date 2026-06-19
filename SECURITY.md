# Security Policy

## Reporting vulnerabilities

REDnet is infrastructure for at-risk communities. If you find a security vulnerability, **report it privately**. Do not open a public issue.

Email: **wlcarden@gmail.com**

Include:

- Description of the vulnerability
- Steps to reproduce or a proof of concept
- Which component is affected (onboarding module, deploy scripts, hardening config, escrow crypto, etc.)
- Assessed severity and impact

You will receive an acknowledgment within 72 hours.

## Scope

**In scope:**

- The deployment stack (`deploy/`): Synapse hardening, MAS config, Caddy proxy rules, Docker composition
- The onboarding module (`deploy/element-web/rednet-module/`): CryptoSetupExtensions, key bootstrap, recovery
- The escrow crypto layer: Shamir, ECIES, scrypt KDF, AAD binding
- Operational scripts: `setup.sh`, `backup.sh`, `restore.sh`, `scrub-metadata.sh`
- The Ansible two-host scaffold (`deploy/ansible/`)
- Threat model gaps: scenarios where the documented protections don't hold

**Out of scope:**

- Upstream vulnerabilities in Synapse, MAS, Element Web, PostgreSQL, or their dependencies (report to those projects directly)
- Denial of service against the deployment
- Social engineering

## Current status

An AI-assisted security review (71 agents, 9 dimensions) covered the full stack; see [SECURITY-REVIEW.md](SECURITY-REVIEW.md). All critical and high findings are fixed. An independent external review by a human specialist is pending and gates production deployment. See [PRODUCTION.md §1](PRODUCTION.md).
