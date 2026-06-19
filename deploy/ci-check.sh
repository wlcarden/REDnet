#!/usr/bin/env bash
# REDnet CI — runnable lint/validation gate. Two tiers, because they catch DISJOINT bug classes:
#
#   Tier 1 (default, fast, no root): static analysis — shellcheck, yamllint, ansible-lint, hadolint,
#           docker compose config. Catches syntax/parse/permission/style bugs.
#   Tier 2 (--integration, needs Docker + root): the in-sandbox network proofs — validate-docker-firewall.sh
#           + validate-wg-aperture.sh. Catches the DNAT/firewall-semantics bugs lint can't see.
#
# The 6 deploy-blocking bugs found by the KVM run were mostly RUNTIME (missing package/dep, undeclared uv,
# unmade dir) — caught by neither tier; the full two-host smoke is deploy/ansible/validate/ (kvm-up.sh).
# So: tier 1 every commit, tier 2 before a release, KVM smoke before trusting a deploy.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
FAIL=0
run(){ local t="$1"; shift; printf '\n=== %s ===\n' "$t"; if "$@"; then echo "  ok"; else echo "  ^^ FAILED"; FAIL=1; fi; }

echo "###################### TIER 1 — static analysis ######################"
run "shellcheck (deploy + validate scripts)" \
    shellcheck -S warning ./*.sh ansible/validate/*.sh element-web/build.sh
run "yamllint (ansible + compose)" \
    yamllint ansible/site.yml docker-compose.yml
run "ansible-lint (site.yml @ profile safety)" \
    ansible-lint -q ansible/site.yml
run "hadolint (Dockerfile, fail on warning+)" \
    hadolint --failure-threshold warning element-web/Dockerfile
run "docker compose config (syntax)" \
    docker compose -f docker-compose.yml config -q

case "${1:-}" in
  --integration)
    echo
    echo "###################### TIER 2 — in-sandbox network proofs (Docker + root) ######################"
    run "DNAT-bypass + DOCKER-USER fix"  ansible/validate/validate-docker-firewall.sh
    run "WG-aperture scoping"            ansible/validate/validate-wg-aperture.sh
    ;;
  --build)
    echo
    echo "###################### TIER 3 — Element image build + sentinel (Docker, slow) ######################"
    run "Element Docker build (REQUIRE_SILENT_ONBOARDING=1)" \
        docker compose --profile web build --build-arg REDNET_REQUIRE_SILENT_ONBOARDING=1 element
    if [ "$FAIL" -eq 0 ]; then
      run "sentinel check (REDNET_SILENT_ONBOARDING=on in built image)" \
          bash -c 'docker compose --profile web run --rm --no-deps --entrypoint cat element /srv/element/rednet-build.txt | grep -q "REDNET_SILENT_ONBOARDING=on"'
    fi
    ;;
  *)
    echo
    echo "(tier 2 skipped — run './ci-check.sh --integration' for the in-sandbox firewall proofs)"
    echo "(tier 3 skipped — run './ci-check.sh --build' for Element image build + sentinel check)"
    ;;
esac

echo
if [ "$FAIL" -eq 0 ]; then echo "CI: PASS"; else echo "CI: FAIL — see ^^ above"; fi
exit "$FAIL"