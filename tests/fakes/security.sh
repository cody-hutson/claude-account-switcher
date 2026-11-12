#!/bin/bash
# as-fake: recording
#
# Fake security. Records the call and never reads a keychain. Any call whose
# -s service name does not begin with "as-test-" is refused with exit 99, so
# even a mis-wired test cannot name the real credentials item.
#   find-generic-password -s <as-test-...> -w
#     prints $AS_FIXTURE_KEYCHAIN_JSON (fake values only), or exits 44 (item
#     not found) when AS_FAKE_KEYCHAIN=absent

set -u
if [[ -z "${AS_TEST_ROOT:-}" || ! -f "${AS_TEST_ROOT}/.as-test-root" ]]; then
  printf 'security (fake): AS_TEST_ROOT is not a test root; refusing\n' >&2
  exit 98
fi
log="${AS_TEST_ROOT}/calls.log"
line="${0##*/}"
svc=""
prev=""
for arg; do
  [[ "$prev" == "-s" ]] && svc="$arg"
  prev="$arg"
  arg="${arg//$'\t'/\\t}"
  line="${line}"$'\t'"${arg//$'\n'/\\n}"
done
printf '%s\n' "$line" >> "$log"

case "$svc" in
  as-test-*) ;;
  *)
    printf 'security\tREFUSED\t%s\n' "$svc" >> "$log"
    printf "security (fake): service '%s' is not a test service; refusing\n" "$svc" >&2
    exit 99
    ;;
esac

if [[ "${1:-}" != "find-generic-password" ]]; then
  printf 'security (fake): only find-generic-password is simulated\n' >&2
  exit 2
fi
if [[ "${AS_FAKE_KEYCHAIN:-}" == "absent" ]]; then
  printf 'security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.\n' >&2
  exit 44
fi
printf '%s\n' "${AS_FIXTURE_KEYCHAIN_JSON:-}"
exit 0
