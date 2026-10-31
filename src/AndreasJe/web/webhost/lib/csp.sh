#!/usr/bin/env bash
#
# lib/csp.sh — build a Content-Security-Policy from a runtime default plus a
# template's optional "csp" map. A template may only tighten: every source it
# lists for a directive must already be allowed by the default (or be 'none').
#
# shellcheck disable=SC2148

readonly CSP_DEFAULT_STATIC="default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
readonly CSP_DEFAULT_APP="default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
readonly CSP_DEFAULT_PHP="default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; frame-ancestors 'self'; base-uri 'self'; form-action 'self'"

# build_csp <runtime> <template.json> [declaration.json] — prints the header
# value, or fails naming the offending directive. The site's own declaration
# (the operator's choice) then replaces whole directives: its "csp" map.
build_csp() {
    local runtime="$1" tj="$2" decl="${3:-/dev/null}" default
    case "${runtime}" in
        static) default="${CSP_DEFAULT_STATIC}" ;;
        php)    default="${CSP_DEFAULT_PHP}" ;;
        node|python) default="${CSP_DEFAULT_APP}" ;;
        *)      echo "no CSP default for runtime '${runtime}'" >&2; return 1 ;;
    esac
    jq -nr --arg d "${default}" --slurpfile t "${tj}" --slurpfile s "${decl}" '
      def parse: split(";") | map(gsub("^\\s+|\\s+$";"") | select(length>0) | split(" ") | {key: .[0], value: .[1:]}) | from_entries;
      ($d | parse) as $def
      | ($t[0].csp // {}) as $over
      | reduce ($over | to_entries[]) as $e ($def;
          ($def[$e.key] // $def["default-src"] // []) as $allowed
          | if ($e.value | all(. as $s | $s == "'\''none'\''" or ($allowed | index($s)))) then .[$e.key] = $e.value
            else error("template csp loosens \($e.key)") end)
      | . + (($s[0] // {}).csp // {})
      | to_entries | map("\(.key) \(.value | join(" "))") | join("; ")'
}
