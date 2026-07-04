#!/usr/bin/env bash
# REDnet deploy — assemble the hardened core+front stack from rednet.env, bring it up, self-check.
# Usage:
#   ./setup.sh             # two-host (production) — renders configs for CORE mode
#   ./setup.sh --dev       # single-host (dev/lab) — starts the full stack locally
set -uo pipefail
cd "$(dirname "$0")" || exit 1
say(){ printf '\n=== %s ===\n' "$*"; }
# Secrets hygiene (R2): host-only secret files are locked 0600; files bind-mounted into NON-root containers
# (mas/config.yaml -> MAS uid 65532; initdb/init.sql -> postgres) must stay readable by that uid, so we
# chown-to-the-uid when we can (root/Ansible) and fall back to readable otherwise. A blanket umask 077
# breaks those mounts — handled per-file below instead.
jqpy(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
genpw(){ LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32; }  # always exactly 32 alnum chars (~190 bits)
MASIMG=ghcr.io/element-hq/matrix-authentication-service@sha256:fb25648b12e985d1192ea3dc7b6def38f97ca79bacba262daca5b82532e3a3dd # MAS 1.19.0 (digest-pinned; matches docker-compose.yml)

[ -f rednet.env ] || { echo "Copy rednet.env.example -> rednet.env and edit it first."; exit 1; }
set -a; . ./rednet.env; set +a
: "${REDNET_DOMAIN:?}"; : "${REDNET_HTTP_PORT:=8080}"; : "${REDNET_RETENTION_DAYS:=7}"; : "${REDNET_MEDIA_RETENTION_DAYS:=7}"
ACCESS="http://localhost:${REDNET_HTTP_PORT}"   # LOCAL url for the self-check curls (single-host only)
# Advertised PUBLIC base — MAS issuer/public_base + Synapse public_baseurl + the client well-known. MUST be the
# real https://<domain> in a two-host/production deploy (OIDC issuer + cookie Secure flag); localhost in dev. R2.
PUBLIC_BASE="${REDNET_PUBLIC_BASE:-$ACCESS}"
# In core (production) mode a non-https PUBLIC_BASE is a hard error, not a warning
# (F29): it becomes the OIDC issuer + cookie origin, so http:// there ships an
# insecure auth surface. Dev/single mode keeps the localhost fallback.
case "$PUBLIC_BASE" in
  https://*) : ;;
  *) if [ "${REDNET_ROLE:-single}" = core ]; then
       echo "REFUSING: REDNET_PUBLIC_BASE='$PUBLIC_BASE' is not https:// in core mode." >&2
       echo "It is the OIDC issuer + cookie origin — http:// weakens the whole auth surface." >&2
       echo "Set REDNET_PUBLIC_BASE=https://<domain> in rednet.env and re-run." >&2
       exit 1
     fi ;;
esac
mkdir -p mas initdb caddy

# Guard destructive re-runs. REDNET_DOMAIN (Synapse server_name, MAS issuer) and
# the DB password are baked into the persisted volumes at first deploy and cannot
# change afterward without wiping. The postgres volume is the "committed" signal:
# only once it exists do we treat domain + password as immutable. Before it exists
# (incl. a retry after a failed first run) changing them is still fine.
PG_VOLUME_EXISTS=false
docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qE '(^|_)rednet_postgres$' && PG_VOLUME_EXISTS=true
if $PG_VOLUME_EXISTS && [ -f .deployed-domain ]; then
  PRIOR_DOMAIN=$(head -1 .deployed-domain)
  if [ -n "$PRIOR_DOMAIN" ] && [ "$PRIOR_DOMAIN" != "$REDNET_DOMAIN" ]; then
    echo "REFUSING to re-render: this stack was first deployed as '$PRIOR_DOMAIN'," >&2
    echo "but rednet.env now says '$REDNET_DOMAIN'. The domain is baked into the" >&2
    echo "persisted volumes and is immutable (F18). To keep the deployment, restore" >&2
    echo "REDNET_DOMAIN=$PRIOR_DOMAIN in rednet.env. To start over as '$REDNET_DOMAIN'," >&2
    echo "wipe first:  docker compose down -v && rm -f .env .deployed-domain   (DESTROYS ALL DATA)" >&2
    exit 1
  fi
fi

say "secrets (.env)"
PGPW=""; [ -f .env ] && PGPW=$(grep -E '^POSTGRES_PASSWORD=' .env | head -1 | cut -d= -f2-)
if [ -z "$PGPW" ]; then
  # The DB password is baked into rednet_postgres at first init. If the volume
  # exists but .env's password is gone, minting a new one desyncs and Postgres
  # auth fails with an opaque error (F19). Refuse rather than create a mismatch.
  if $PG_VOLUME_EXISTS; then
    echo "rednet_postgres volume exists but POSTGRES_PASSWORD is missing from .env." >&2
    echo "The volume was initialized with a password that is now unreadable, so a new" >&2
    echo "one would not match and Postgres auth would fail (F19). Recover the old .env," >&2
    echo "or wipe and start over:  docker compose down -v && rm -f .env .deployed-domain" >&2
    exit 1
  fi
  PGPW=$(genpw)
fi
cat > .env <<EOF
POSTGRES_PASSWORD=${PGPW}
REDNET_DOMAIN=${REDNET_DOMAIN}
REDNET_HTTP_PORT=${REDNET_HTTP_PORT}
EOF
chmod 600 .env 2>/dev/null || true
# Record the domain so a later re-run with a changed REDNET_DOMAIN is caught above.
printf '%s\n' "$REDNET_DOMAIN" > .deployed-domain
chmod 600 .deployed-domain 2>/dev/null || true
echo "POSTGRES_PASSWORD set; REDNET_DOMAIN=${REDNET_DOMAIN}"

say "render MAS config (no-PII, delegated)"
[ -f mas/config.yaml ] || docker run --rm $MASIMG config generate 2>/dev/null > mas/config.yaml
# uv (dev machine) supplies an ephemeral pyyaml; on a clean deploy host fall back to system python3 +
# the python3-yaml package (installed by the Ansible). Keeps dev behavior, removes the hard uv dependency.
if command -v uv >/dev/null 2>&1; then PYRUN="uv run --quiet --with pyyaml python3"; else PYRUN="python3"; fi
MAS_SECRET=$($PYRUN - "$REDNET_DOMAIN" "$PUBLIC_BASE" "$PGPW" "${REDNET_BRAND:-REDnet}" <<'PY'
import sys,yaml
domain,access,pgpw=sys.argv[1],sys.argv[2],sys.argv[3]
brand=sys.argv[4] if len(sys.argv)>4 else "REDnet"
p="mas/config.yaml"; c=yaml.safe_load(open(p))
c["database"]={"uri":f"postgresql://synapse:{pgpw}@postgres/mas"}
c["http"]["public_base"]=access+"/"; c["http"]["issuer"]=access+"/"
c["http"]["trusted_proxies"]=["172.16.0.0/12"]  # R2: only the docker network (where Caddy connects from), not the default over-broad range
c["matrix"]["homeserver"]=domain; c["matrix"]["endpoint"]="http://synapse:8008/"
acct=c.setdefault("account",{})
acct["password_registration_enabled"]=True
acct["password_registration_email_required"]=False  # no PII (SPEC §5)
acct["password_registration_token_required"]=True    # ★ invite-token gate: closed, attributable entry (SPEC §5).
pw=c.setdefault("passwords",{})
pw["enabled"]=True
pw["minimum_complexity"]=3  # ★ pin the zxcvbn strength floor (F37): a MAS default change can't silently weaken it (nor resurrect the "rejected as too weak" UX base.html works around).
# Organizers mint registration tokens via the MAS admin API / `mas-cli manage`; the append-only mint log is
# the coercion canary (DESIGN §7/§11). Without this, anyone reaching the front can self-register.
# Auth branding: the VISUAL rebrand (logo + REDnet accent + reframed "Redeem your invite") is the
# base.html overlay bind-mounted in docker-compose; this branding block adds the service name + the
# footer policy link. logo_uri/policy_uri are same-origin paths served by the front. (Auth branding notes
# in mas/templates/base.html.)
c["branding"]={"service_name":brand,
               "logo_uri":access+"/themes/element/img/logos/rednet.svg",
               "policy_uri":access+"/safety"}
# --- Invite minting (COMMUNITY-MANAGEMENT.md): mint-svc is the SOLE holder of MAS-admin,
# behind one operation. Expose the admin REST API, register a client_credentials client, and
# allow it admin. bootstrap-gov-bot.sh reads this client's id/secret to render mint-svc/.env.
import secrets as _sec, time as _t, random as _rnd
def _ulid():
    _a='0123456789ABCDEFGHJKMNPQRSTVWXYZ'; _ms=int(_t.time()*1000)
    return ''.join(_a[(_ms>>(50-_i*5))&31] for _i in range(10))+''.join(_rnd.choice(_a) for _ in range(16))
for _l in c["http"]["listeners"]:            # serve /api/admin/v1 (off by default)
    if _l.get("name")=="web" and "adminapi" not in [_r.get("name") for _r in _l["resources"]]:
        _l["resources"].append({"name":"adminapi"})
_ac=c.setdefault("policy",{}).setdefault("data",{}).setdefault("admin_clients",[])
if _ac:                                       # idempotent: reuse the existing mint client on re-render
    _cid=_ac[0]
else:
    _cid=_ulid()
    c.setdefault("clients",[]).append({"client_id":_cid,"client_auth_method":"client_secret_post",
                                       "client_secret":_sec.token_urlsafe(32)})
    _ac.append(_cid)
yaml.safe_dump(c,open(p,"w")); print(c["matrix"]["secret"])
PY
)
[ -n "${MAS_SECRET:-}" ] || { echo "MAS config render failed"; exit 1; }
# carries secrets.encryption + the DB password; read by the MAS container (uid 65532, non-root).
if chown 65532:65532 mas/config.yaml 2>/dev/null; then chmod 600 mas/config.yaml; else chmod 644 mas/config.yaml; fi
echo "CREATE DATABASE mas;" > initdb/init.sql
cat > caddy/well-known-client.json <<EOF
{"m.homeserver":{"base_url":"${PUBLIC_BASE}"}}
EOF
echo "MAS config rendered (shared secret ${MAS_SECRET:0:6}...)"

say "start postgres (synapse + mas DBs)"
docker compose up -d postgres
until docker compose exec -T postgres pg_isready -U synapse >/dev/null 2>&1; do sleep 2; done
echo "postgres ready"

say "MAS: migrate + start"
docker compose run --rm -T mas database migrate --config /config.yaml 2>&1 | tail -2 || true
docker compose up -d mas

say "Synapse: generate + HARDEN + delegate to MAS"
docker compose run --rm -T synapse generate >/dev/null 2>&1
DOMAIN="$REDNET_DOMAIN" PGPW="$PGPW" ACCESS="$PUBLIC_BASE" RET="$REDNET_RETENTION_DAYS" MRET="$REDNET_MEDIA_RETENTION_DAYS" MAS_SECRET="$MAS_SECRET" \
docker compose run --rm -T -e DOMAIN -e PGPW -e ACCESS -e RET -e MRET -e MAS_SECRET --entrypoint python3 synapse - <<'PY'
import yaml,os
p="/data/homeserver.yaml"; c=yaml.safe_load(open(p))
c["database"]={"name":"psycopg2","args":{"user":"synapse","password":os.environ["PGPW"],"database":"synapse","host":"postgres","cp_min":5,"cp_max":10}}
c["report_stats"]=False; c["public_baseurl"]=os.environ["ACCESS"]+"/"; c["serve_server_wellknown"]=False
# delegate auth to MAS (stable block; secret via file to avoid the inline-secret restriction)
open("/data/mas_shared_secret","w").write(os.environ["MAS_SECRET"])
c["matrix_authentication_service"]={"enabled":True,"endpoint":"http://mas:8080","secret_path":"/data/mas_shared_secret"}
c["password_config"]={"enabled":False}
c.pop("enable_registration",None); c.pop("registration_shared_secret",None)
# --- HARDENING (SPEC §4) ---
c["federation_domain_whitelist"]=[]
c["trusted_key_servers"]=[]   # closed island — drop the default outbound matrix.org key-server dependency (R2)
c["presence"]={"enabled":False}
c["url_preview_enabled"]=False
c["encryption_enabled_by_default_for_room_type"]="off"  # R2: bootstrap scripts add E2EE explicitly (initial_state); Element Web forces it via io.element.e2ee.default:true. Server-side "all" was silently encrypting bot rooms (#gov-bot, #rednet-mod) that MUST be plaintext — bots use HTTP, not Olm.
# push hygiene: stock apps route through Element's gateway (a known metadata vector, ARCHITECTURE.md);
# never hand message content to it. For E2EE rooms the body is ciphertext anyway — this is belt+braces.
c["push"]={"include_content":False}
RET=os.environ["RET"]; MRET=os.environ["MRET"]
c["retention"]={"enabled":True,"default_policy":{"max_lifetime":f"{RET}d"},
  "allowed_lifetime_min":"1h","allowed_lifetime_max":"30d",
  "purge_jobs":[{"longest_max_lifetime":"1d","interval":"30m"},{"shortest_max_lifetime":"1d","interval":"12h"}]}
c["media_retention"]={"local_media_lifetime":f"{MRET}d"}
c["user_ips_max_age"]="1d"; c["redaction_retention_period"]="1d"
c["rc_registration"]={"per_second":0.05,"burst_count":3}
# Per-IP login throttle is now the FRONT's job (the core sees a placeholder IP — R2 privacy), so `address`
# is effectively off here; per-ACCOUNT throttle + failed-attempt lockout (unaffected by the placeholder) is
# the real brute-force defense, kept tight. Add per-IP rate-limiting at the front edge for credential-stuffing.
c["rc_login"]={"address":{"per_second":1000,"burst_count":1000},"account":{"per_second":0.17,"burst_count":5},"failed_attempts":{"per_second":0.17,"burst_count":5}}
c["rc_invites"]={"per_room":{"per_second":0.1,"burst_count":5},"per_user":{"per_second":0.1,"burst_count":5},"per_issuer":{"per_second":0.1,"burst_count":5}}  # SPEC §4 (R2)
# Closed network — no untrusted traffic to throttle. Default 0.2/s burst 10 is for public servers; raise for
# bot burst operations (revoke-chain kicks, DM creation sweeps) without needing a synapse-admin credential.
c["rc_message"]={"per_second":0.5,"burst_count":50}
c["rc_joins"]={"local":{"per_second":0.5,"burst_count":20},"remote":{"per_second":0.01,"burst_count":1}}
c["default_room_version"]="12"
# auto-join the system rooms (created by bootstrap-rooms.sh)
_d=os.environ['DOMAIN']  # land members inside the space + its starter channels
c["auto_join_rooms"]=[f"#{a}:{_d}" for a in ("community","welcome","announcements","general")]
c["auto_join_mxid_localpart"]="rednet-system"
c["autocreate_auto_join_rooms"]=False
# --- room-creation lockdown (COMMUNITY-MANAGEMENT.md): only system accounts create shared
# rooms; members' clients keep DMs. Module mounted at /modules (compose sets PYTHONPATH).
_creators=[f"@rednet-system:{_d}",f"@rednet-gov:{_d}",f"@rednet-mod:{_d}"]
c["modules"]=[{"module":"rednet_room_policy.RednetRoomPolicy","config":{"allowed_creators":_creators}}]
# Layered: alias squatting (#general2 phishing) blocked even if the module fails to load,
# and nothing ever publishes to the room directory — the space hierarchy IS the directory.
c["alias_creation_rules"]=[{"user_id":u,"alias":"*","room_id":"*","action":"allow"} for u in _creators]+[{"user_id":"*","alias":"*","room_id":"*","action":"deny"}]
c["room_list_publication_rules"]=[{"user_id":"*","alias":"*","room_id":"*","action":"deny"}]
# close the federation port: keep only the client resource on the 8008 listener + trust the proxy.
# ALSO add "openid" — it serves ONLY /_matrix/federation/v1/openid/userinfo (identity verification for
# the governance widget's mint flow), NOT federation traffic. The front (Caddy) still blocks external
# /_matrix/federation/*; the gov-bot verifies OpenID tokens internally. (COMMUNITY-MANAGEMENT.md.)
for l in c.get("listeners",[]):
    if l.get("port")==8008:
        l["x_forwarded"]=True
        for r in l.get("resources",[]):
            if "names" in r:
                r["names"]=[n for n in r["names"] if n!="federation"]
                if "openid" not in r["names"]: r["names"].append("openid")
# metrics listener — CORE-internal only (NOT published to the host); Prometheus scrapes it over the
# private docker network / WireGuard. enable_metrics gates Synapse's /_synapse/metrics exporter.
c["enable_metrics"]=True
if not any(l.get("type")=="metrics" for l in c.get("listeners",[])):
    c["listeners"].append({"port":9000,"type":"metrics","bind_addresses":["0.0.0.0"]})
# quiet per-request access logging — it records client IP + MXID + path (who-did-what-when). LOG-HYGIENE.md
lcp=c.get("log_config")
if lcp and os.path.exists(lcp):
    lc=yaml.safe_load(open(lcp)); lc.setdefault("loggers",{})["synapse.access"]={"level":"WARN"}; yaml.safe_dump(lc,open(lcp,"w"))
yaml.safe_dump(c,open(p,"w")); print("synapse hardened + delegating to MAS")
PY

DEV_MODE=false
for arg in "$@"; do [ "$arg" = "--dev" ] && DEV_MODE=true; done
ROLE="${REDNET_ROLE:-core}"   # core = two-host data plane (production default) | single = dev/lab (requires --dev)
$DEV_MODE && ROLE=single
if [ "$ROLE" = single ] && ! $DEV_MODE; then
  echo "Single-host mode requires --dev flag: ./setup.sh --dev"
  echo "Production deployments use two-host mode by default (see PRODUCTION.md #3)."
  exit 1
fi
if [ "$ROLE" = core ]; then
  # R2 CRITICAL: the core must be DARK. setup.sh must NOT start caddy or publish any 0.0.0.0 host port here —
  # the Ansible core play brings up the WG-bound stack (-f docker-compose.wg.yml); the front lives on its own box.
  say "CORE mode: configs rendered + HARDENED; NO caddy / NO public host port started on the core"
  echo "The Ansible core play brings up the WG-bound data plane. Self-check + ./bootstrap-rooms.sh run AGAINST THE"
  echo "FRONT, post-front-deploy. Verify dark: from off-host, 'nc -vz <core_public_ip> 8008 8080' must FAIL."
  exit 0
fi
say "⚠️  DEV/LAB MODE — single-host, not for production"
echo "This mode runs the entire stack on one host. For production, use two-host mode"
echo "(CORE + FRONT on separate boxes with WireGuard). See PRODUCTION.md #3."
say "start synapse + caddy (front)"
docker compose up -d synapse caddy
echo "waiting for the front..."
for _ in $(seq 1 60); do curl -sf $ACCESS/_matrix/client/versions >/dev/null 2>&1 && break; sleep 2; done
curl -sf $ACCESS/_matrix/client/versions >/dev/null 2>&1 || { echo "FRONT->SYNAPSE UNREACHABLE"; docker compose logs synapse caddy | tail -50; exit 1; }
echo "Synapse reachable via the front"
for _ in $(seq 1 30); do curl -sf $ACCESS/.well-known/openid-configuration >/dev/null 2>&1 && break; sleep 2; done
curl -sf $ACCESS/.well-known/openid-configuration >/dev/null 2>&1 && echo "MAS reachable via the front" || { echo "FRONT->MAS UNREACHABLE"; docker compose logs mas caddy | tail -40; exit 1; }

say "SELF-CHECK: no-PII account + MAS-delegated token accepted by Synapse through the front"
docker compose exec -T mas mas-cli manage register-user rednetcheck --password "$(genpw)" --yes --ignore-password-complexity --config /config.yaml 2>&1 | tail -1
TOK=$(docker compose exec -T mas mas-cli manage issue-compatibility-token rednetcheck CHECKDEV --config /config.yaml 2>&1 | grep -oE '(mct_|syt_)[A-Za-z0-9_]+' | head -1)
WHO=$(curl -s -H "Authorization: Bearer $TOK" $ACCESS/_matrix/client/v3/account/whoami | jqpy "d.get('user_id','')")
echo "whoami via front -> ${WHO:-<failed>}"
EMAILS=$(docker compose exec -T postgres psql -U synapse -d mas -tAc "SELECT count(*) FROM user_emails;" 2>/dev/null | tr -d '[:space:]')
docker compose exec -T mas mas-cli manage lock-user rednetcheck --config /config.yaml >/dev/null 2>&1 || true

say "VERDICT"
PASS=1
[ "$WHO" = "@rednetcheck:${REDNET_DOMAIN}" ] || { PASS=0; echo "FAIL: MAS delegation through the front not working"; }
[ "${EMAILS:-1}" = "0" ] || { PASS=0; echo "FAIL: a PII email exists in MAS (${EMAILS})"; }
grep -q 'password_registration_token_required: true' mas/config.yaml || { PASS=0; echo "FAIL: OPEN REGISTRATION — invite-token gate not set (SPEC §5); anyone reaching the front could self-register"; }
grep -q 'minimum_complexity: 3' mas/config.yaml || { PASS=0; echo "FAIL: password strength floor not pinned (F37) — minimum_complexity should be 3"; }
# behavioral: drive a token-less registration through the front; it must create NO account (SPEC §5 gate).
# MAS registration is multi-step + CSRF-protected; the token is enforced before account creation, so a
# token-less attempt cannot complete. (Parallel to the no-PII email assertion above.)
RJ=$(mktemp); RH=$(mktemp)
curl -s -c "$RJ" "$ACCESS/register/password" -o "$RH" 2>/dev/null
RCSRF=$(grep -ioE 'name="csrf"[^>]*value="[^"]*"' "$RH" 2>/dev/null | grep -ioE 'value="[^"]*"' | sed 's/value="//;s/"//' | head -1)
curl -s -b "$RJ" -XPOST "$ACCESS/register/password" -o /dev/null 2>/dev/null \
  -d "username=gatecheck&password=Gate-Check-Pw-42x&password_confirm=Gate-Check-Pw-42x&csrf=${RCSRF}"
GATEREG=$(docker compose exec -T postgres psql -U synapse -d mas -tAc "SELECT count(*) FROM users WHERE username='gatecheck';" 2>/dev/null | tr -d '[:space:]')
rm -f "$RJ" "$RH"
[ "${GATEREG:-1}" = "0" ] || { PASS=0; echo "FAIL: token-less registration CREATED an account — the SPEC §5 invite-token gate is not enforced"; }
# confirm hardening landed
HARD=$(docker compose exec -T synapse python3 -c "import yaml;c=yaml.safe_load(open('/data/homeserver.yaml'));print('fed=%s presence=%s urlprev=%s push_content=%s metrics=%s ret=%s'%(c.get('federation_domain_whitelist'),c['presence']['enabled'],c.get('url_preview_enabled'),c.get('push',{}).get('include_content'),c.get('enable_metrics'),c['retention']['default_policy']['max_lifetime']))" 2>/dev/null)
echo "hardening: $HARD"
if [ "$PASS" = 1 ]; then
  echo "PASS: hardened, MAS-delegated, two-tier stack is UP — no-PII account works through the front."
  ./bootstrap-rooms.sh || echo "(room bootstrap had issues — see above)"
fi
echo; echo "Front: $ACCESS   ·   stop: docker compose down   ·   wipe: docker compose down -v"
