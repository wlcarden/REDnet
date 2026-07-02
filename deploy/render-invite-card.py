#!/usr/bin/env python3
"""Render a REDnet invite in one of several print/screen formats.

Shared by both minting paths so they produce identical output:
  - mint-invite.sh (the CLI / SSH path)
  - the in-client minting endpoint (governance dashboard, Option C)

The TOKEN only ever reaches this renderer's output (a local file / an HTTP
response to the operator's own browser) — never a Matrix room. #vouch-log gets
the SHA-256 hash only. Keep it that way.

Usage:
  render-invite-card.py --format print-card \
    --token TOKEN --domain rednet.test --brand REDnet \
    --label "Maria, Tue group" --voucher @alice:rednet.test \
    --expires "2026-07-09"

Formats: print-card (3.5x2.25"), wallet (3.375x2.125"), half-sheet (5.5x8.5"),
         plain (text, no HTML). Writes HTML/text to stdout.
Requires: qrencode on PATH (for the QR SVG). --no-qr skips it (plain text).
"""

import argparse
import html
import subprocess
import sys


def qr_svg(data):
    """Return an inline <svg> QR (no XML prolog) via qrencode, or '' on failure."""
    try:
        out = subprocess.run(
            ["qrencode", "-t", "SVG", "-o", "-", "-l", "M", "-m", "0", data],
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    # strip everything before the opening <svg ...>
    i = out.find("<svg")
    return out[i:] if i >= 0 else ""


# ── shared palette (matches /join + the branded auth) ────────────────────────
ACCENT = "#E5484D"
INK = "#16181B"
INK2 = "#2A2D33"
MUTE = "#8B8D98"
FAINT = "#62646C"
HAIR = "#ECEDEE"

# REDnet mesh mark (compact, self-contained so a card needs no external asset)
LOGO = (
    '<svg viewBox="0 0 252 64" xmlns="http://www.w3.org/2000/svg" aria-label="REDnet">'
    '<g stroke="#E5484D" stroke-width="2" stroke-opacity="0.7" fill="none">'
    '<path d="M32 12 L52 26 L44 50 L20 50 L12 26 Z"/>'
    '<path d="M32 12 L32 32 M52 26 L32 32 M44 50 L32 32 M20 50 L32 32 M12 26 L32 32"/>'
    "</g>"
    '<g fill="#E5484D"><circle cx="32" cy="12" r="3.5"/><circle cx="52" cy="26" r="3.5"/>'
    '<circle cx="44" cy="50" r="3.5"/><circle cx="20" cy="50" r="3.5"/>'
    '<circle cx="12" cy="26" r="3.5"/></g><circle cx="32" cy="32" r="4" fill="#E5484D"/>'
    '<text x="72" y="42" font-family="Inter,system-ui,sans-serif" font-size="34" '
    'font-weight="800" letter-spacing="-1">'
    '<tspan fill="#E5484D">RED</tspan><tspan fill="#8B8D98">net</tspan></text></svg>'
)

BASE_CSS = f"""
  * {{ margin:0; padding:0; box-sizing:border-box; }}
  html, body {{ background:#fff; }}
  body {{ font-family: Inter, system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif;
          display:flex; align-items:center; justify-content:center; padding:0.2in; }}
  .qr svg {{ width:100%; height:100%; display:block; }}
  .brandrow svg {{ width:auto; }}
  .url {{ color:{ACCENT}; font-weight:700; word-break:break-all; }}
  .code {{ font-family:'SF Mono','Fira Code',ui-monospace,monospace; color:{INK};
           letter-spacing:0.2px; word-break:break-all; }}
  .lab {{ font-weight:700; letter-spacing:0.5px; text-transform:uppercase; color:{MUTE}; }}
  .warn {{ color:{ACCENT}; font-weight:700; }}
"""


def _footer_line(expires):
    exp = f" · Expires {html.escape(expires)}" if expires else ""
    return f"Single-use{exp} · Do not share or post online."


def card_common(token, join_url, domain, brand, label, expires, wallet=False):
    """Print-card / wallet-card (same layout, different physical size)."""
    w, h = ("3.375in", "2.125in") if wallet else ("3.5in", "2.25in")
    qr = (
        qr_svg(join_url)
        or '<div style="font-size:8px;color:#888">[QR unavailable]</div>'
    )
    page = f"@page {{ size:{w} {h}; margin:0; }}"
    return f"""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<title>{html.escape(brand)} invite</title><style>{page}{BASE_CSS}
  .card {{ width:{w}; height:{h}; background:#fff; color:{INK}; border:1.5px solid {ACCENT};
           border-radius:10px; padding:0.15in 0.17in; display:flex; gap:0.15in; position:relative; }}
  .accent {{ position:absolute; left:0; top:0; bottom:0; width:5px; background:{ACCENT};
             border-radius:9px 0 0 9px; }}
  .left {{ flex:0 0 auto; display:flex; flex-direction:column; align-items:center; gap:4px; }}
  .qr {{ width:1.2in; height:1.2in; }}
  .scan {{ font-size:7px; font-weight:700; letter-spacing:0.4px; color:{FAINT}; text-transform:uppercase; }}
  .right {{ flex:1; min-width:0; display:flex; flex-direction:column; }}
  .brandrow svg {{ height:14px; }}
  .headline {{ font-size:13.5px; font-weight:800; letter-spacing:-0.3px; color:{INK}; margin:3px 0 4px; }}
  .steps {{ font-size:8.5px; line-height:1.5; color:{INK2}; }}
  .steps b {{ color:{INK}; }}
  .url {{ font-size:9px; margin-top:2px; }}
  .backup {{ margin-top:auto; padding-top:5px; border-top:1px solid {HAIR}; }}
  .backup .lab {{ font-size:6.5px; }}
  .backup .code {{ font-size:8.5px; }}
  .foot {{ font-size:6.5px; color:{MUTE}; margin-top:4px; }}
</style></head><body>
<div class="card"><div class="accent"></div>
  <div class="left"><div class="qr">{qr}</div><div class="scan">Scan to join</div></div>
  <div class="right">
    <div class="brandrow">{LOGO}</div>
    <div class="headline">You've been invited</div>
    <div class="steps"><b>1.</b> Scan the code, or go to<div class="url">{html.escape(domain)}/join</div>
      <b>2.</b> Read the short setup guide<br>
      <b>3.</b> Create your account &amp; save your recovery passphrase</div>
    <div class="backup"><div class="lab">Backup code (only if the QR won't scan)</div>
      <div class="code">{html.escape(token)}</div></div>
    <div class="foot"><span class="warn">{_footer_line(expires)}</span></div>
  </div>
</div></body></html>"""


def half_sheet(token, join_url, domain, brand, label, expires):
    """Half-letter (5.5x8.5") instruction sheet — QR + OPSEC guidance from /join."""
    qr = (
        qr_svg(join_url)
        or '<div style="font-size:12px;color:#888">[QR unavailable]</div>'
    )
    return f"""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<title>{html.escape(brand)} invite</title><style>@page {{ size:5.5in 8.5in; margin:0; }}{BASE_CSS}
  body {{ align-items:flex-start; }}
  .sheet {{ width:5.5in; min-height:8.5in; background:#fff; color:{INK}; padding:0.5in 0.55in;
            border-top:6px solid {ACCENT}; }}
  .brandrow svg {{ height:22px; }}
  h1 {{ font-size:26px; font-weight:800; letter-spacing:-0.5px; margin:14px 0 4px; }}
  .sub {{ font-size:12px; color:{MUTE}; margin-bottom:16px; }}
  .qrbox {{ display:flex; gap:16px; align-items:center; padding:14px; border:1.5px solid {ACCENT};
            border-radius:10px; margin-bottom:16px; }}
  .qr {{ width:1.7in; height:1.7in; flex:0 0 auto; }}
  .qrbox .u {{ font-size:12px; }}
  .qrbox .url {{ font-size:15px; margin-top:4px; }}
  .lab {{ font-size:9px; }}
  .code {{ font-size:12px; margin-top:2px; }}
  h2 {{ font-size:11px; font-weight:800; letter-spacing:0.6px; text-transform:uppercase;
        color:{FAINT}; margin:16px 0 6px; }}
  .tip {{ font-size:12px; line-height:1.55; color:{INK2}; margin-bottom:8px; }}
  .tip b {{ color:{INK}; }}
  .foot {{ font-size:10px; margin-top:18px; padding-top:10px; border-top:1px solid {HAIR}; color:{MUTE}; }}
</style></head><body>
<div class="sheet">
  <div class="brandrow">{LOGO}</div>
  <h1>You've been invited</h1>
  <div class="sub">This takes about five minutes. Read it before you create your account — it protects you.</div>
  <div class="qrbox">
    <div class="qr">{qr}</div>
    <div><div class="u">Scan the code, or go to:</div><div class="url">{html.escape(domain)}/join</div>
      <div class="lab" style="margin-top:10px">Backup code (only if the QR won't scan)</div>
      <div class="code">{html.escape(token)}</div></div>
  </div>
  <h2>Before you start</h2>
  <div class="tip"><b>Pick a username that isn't your real name</b> and that you don't use anywhere
    else. Anyone with server access can see it — a handle that identifies you, or one you reuse on
    other platforms, links this account back to you.</div>
  <div class="tip"><b>Save your recovery passphrase.</b> During setup the app shows you one. Write it
    on paper or store it in a password manager — not a notes app, not a screenshot. It is the only way
    back in on a new device.</div>
  <div class="tip"><b>Turn off lock-screen message previews</b> so notifications don't show content to
    anyone holding your phone.</div>
  <div class="foot"><span class="warn">{_footer_line(expires)}</span><br>
    Having trouble? Ask the person who gave you this invite.</div>
</div></body></html>"""


def plain(token, join_url, domain, brand, label, expires):
    exp = f"\nExpires:  {expires}" if expires else ""
    lab = f"\nFor:      {label}" if label else ""
    return f"""{brand} invite{lab}

Join:     {domain}/join
Token:    {token}
Link:     {join_url}{exp}

Single-use. Do not share or post online. Read the setup guide before creating your account.
"""


RENDERERS = {
    "print-card": lambda **k: card_common(wallet=False, **k),
    "wallet": lambda **k: card_common(wallet=True, **k),
    "half-sheet": half_sheet,
    "plain": plain,
}


def main():
    ap = argparse.ArgumentParser(description="Render a REDnet invite card.")
    ap.add_argument("--format", choices=list(RENDERERS), default="print-card")
    ap.add_argument("--token", required=True)
    ap.add_argument("--domain", required=True, help="server_name, e.g. rednet.test")
    ap.add_argument("--brand", default="REDnet")
    ap.add_argument("--label", default="")
    ap.add_argument("--voucher", default="")
    ap.add_argument("--expires", default="", help="human date, e.g. 2026-07-09")
    ap.add_argument(
        "--public-base",
        default="",
        help="override join URL base (default https://<domain>)",
    )
    args = ap.parse_args()

    base = args.public_base or f"https://{args.domain}"
    join_url = f"{base}/join#{args.token}"
    sys.stdout.write(
        RENDERERS[args.format](
            token=args.token,
            join_url=join_url,
            domain=args.domain,
            brand=args.brand,
            label=args.label,
            expires=args.expires,
        )
    )


if __name__ == "__main__":
    main()
