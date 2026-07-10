#!/bin/bash
# tests/run-tests.sh - awsconfd test suite.
# Plain bash, no framework, no dependencies. Exit 0 on pass.
# Each test runs in a fresh temp HOME-alike via AWSCONFD_CONFIG_DIR /
# AWSCONFD_CONFIG_FILE / XDG_CONFIG_HOME, so tests never touch the real
# ~/.aws or ~/.config.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
BIN="${REPO_DIR}/awsconfd"

PASS=0
FAIL=0
FAILED_NAMES=()

TESTROOT="$(mktemp -d "${TMPDIR:-/tmp}/awsconfd-tests.XXXXXX")"
trap 'rm -rf "$TESTROOT"' EXIT

# --- test harness -----------------------------------------------------

_case_dir=""
_case_home=""

setup_case() {
    local name="$1"
    _case_dir="${TESTROOT}/${name}"
    mkdir -p "$_case_dir"
    _case_home="$_case_dir/home"
    mkdir -p "$_case_home"
    export HOME="$_case_home"
    export AWSCONFD_CONFIG_FILE="${_case_home}/.aws/config"
    export XDG_CONFIG_HOME="${_case_home}/.config"
    unset AWSCONFD_CONFIG_DIR AWS_CONFIG_FILE
    # Tests intentionally leave AWSCONFD_CONFIG_DIR unset so the binary
    # derives it itself (exercising A6.2's re-derivation). CONFIG_D below
    # is the test script's OWN local knowledge of where that will land,
    # used only for setting up/inspecting fixture files directly.
    CONFIG_D="${_case_home}/.aws/config.d"
}

pass() {
    PASS=$((PASS + 1))
    printf '  [PASS] %s\n' "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$1")
    printf '  [FAIL] %s\n' "$1"
    [[ -n ${2:-} ]] && printf '         %s\n' "$2"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$desc"
    else
        fail "$desc" "expected [$expected] got [$actual]"
    fi
}

assert_exit() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$desc"
    else
        fail "$desc" "expected exit $expected got $actual"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc" "expected output to contain: $needle"
    fi
}

assert_true() {
    local desc="$1" cond="$2"
    if [[ $cond -eq 0 ]]; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

section() {
    printf '\n=== %s ===\n' "$1"
}

# =============================================================================
section "Portability (A9 / spec §16)"
# =============================================================================

FORBIDDEN_PATTERNS=(
    'declare -A' 'mapfile' 'readarray' 'local -n' 'sed -i' 'readlink -f'
    'realpath' 'stat -c' 'stat -f' 'grep -P' 'sort -V' '\$\{[a-zA-Z_]+,,\}'
    '\$\{[a-zA-Z_]+\^\^\}' '\bjq\b' '\byq\b'
)
forbidden_hit=0
for pat in "${FORBIDDEN_PATTERNS[@]}"; do
    hit="$(grep -vE '^\s*#' "$BIN" "${REPO_DIR}/install.sh" 2>/dev/null | grep -En -- "$pat" || true)"
    if [[ -n $hit ]]; then
        fail "forbidden construct absent: $pat" "found: $hit"
        forbidden_hit=1
    fi
done
[[ $forbidden_hit -eq 0 ]] && pass "no forbidden bash4/GNU-only/stat/jq/yq constructs in awsconfd or install.sh (outside comments)"

if grep -Enq '^\s*\(\([a-zA-Z_]+\+\+\)\)\s*$' "$BIN"; then
    fail "no standalone ((var++)) as a statement (A0.1)"
else
    pass "no standalone ((var++)) as a statement (A0.1)"
fi

bash -n "$BIN" && pass "bash -n syntax check" || fail "bash -n syntax check"

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -s bash -S error "$BIN" >/dev/null 2>&1; then
        pass "shellcheck -S error"
    else
        fail "shellcheck -S error" "$(shellcheck -s bash -S error "$BIN" 2>&1 | head -5)"
    fi
else
    printf '  [SKIP] shellcheck not installed\n'
fi

# =============================================================================
section "set -e survival (A0.2 / A9)"
# =============================================================================

setup_case "seteq"
"$BIN" init -y >/dev/null 2>&1
out=$("$BIN" -q status --check 2>&1); rc=$?
assert_true "status --check under -q does not crash (rc<128)" "$([[ $rc -lt 128 ]] && echo 0 || echo 1)"
out=$("$BIN" -v doctor 2>&1); rc=$?
assert_true "doctor under -v does not crash (rc<128)" "$([[ $rc -lt 128 ]] && echo 0 || echo 1)"
rm -rf "$CONFIG_D"/*.conf
out=$("$BIN" build 2>&1); rc=$?
assert_true "build over an empty config.d does not crash (rc<128)" "$([[ $rc -lt 128 ]] && echo 0 || echo 1)"

# =============================================================================
section "Build"
# =============================================================================

setup_case "build_empty"
"$BIN" init -y >/dev/null 2>&1
rm -f "$CONFIG_D"/*.conf
"$BIN" build --quiet
out="$(cat "$AWSCONFD_CONFIG_FILE")"
assert_contains "empty config.d -> banner only" "$out" "awsconfd-generated: v1"
lines_with_bracket=$(grep -c '^\[' "$AWSCONFD_CONFIG_FILE" || true)
assert_eq "empty config.d -> no section lines" "0" "$lines_with_bracket"

setup_case "build_two_fragments"
"$BIN" init -y >/dev/null 2>&1
cat > "$CONFIG_D/00-defaults.conf" << 'EOF'
[default]
region = eu-west-2
EOF
cat > "$CONFIG_D/10-sso.conf" << 'EOF'
[sso-session personal]
sso_start_url = https://d-123.awsapps.com/start
sso_region = eu-west-2
EOF
"$BIN" build --quiet
out="$(cat "$AWSCONFD_CONFIG_FILE")"
assert_contains "two fragments both present" "$out" "[default]"
assert_contains "two fragments both present (2)" "$out" "[sso-session personal]"
assert_contains "provenance comments present by default" "$out" "-- 00-defaults.conf"
order_ok=1
python3 -c "
import sys
t = open('$AWSCONFD_CONFIG_FILE').read()
sys.exit(0 if t.index('00-defaults.conf') < t.index('10-sso.conf') else 1)
" 2>/dev/null || order_ok=0
assert_true "fragments in LC_ALL=C filename order" "$([[ $order_ok -eq 1 ]] && echo 0 || echo 1)"

setup_case "build_no_provenance"
"$BIN" init -y >/dev/null 2>&1
cat > "$CONFIG_D/00-defaults.conf" << 'EOF'
[default]
region = eu-west-2
EOF
"$BIN" build --no-provenance --quiet
out="$(cat "$AWSCONFD_CONFIG_FILE")"
if [[ "$out" == *"----"* ]]; then
    fail "--no-provenance suppresses provenance lines"
else
    pass "--no-provenance suppresses provenance lines"
fi

setup_case "build_missing_trailing_newline"
"$BIN" init -y >/dev/null 2>&1
printf '[default]\nregion = eu-west-2' > "$CONFIG_D/00-defaults.conf"
before_sum=$(cksum < "$CONFIG_D/00-defaults.conf")
"$BIN" build --quiet
after_sum=$(cksum < "$CONFIG_D/00-defaults.conf")
assert_eq "fragment on disk untouched by trailing-newline compensation" "$before_sum" "$after_sum"
section_count=$(grep -c '^\[default\]' "$AWSCONFD_CONFIG_FILE")
assert_eq "missing trailing newline doesn't merge with next content" "1" "$section_count"

setup_case "build_idempotent"
"$BIN" init -y >/dev/null 2>&1
cat > "$CONFIG_D/00-defaults.conf" << 'EOF'
[default]
region = eu-west-2
EOF
"$BIN" build --quiet
mtime1=$(stat -c %Y "$AWSCONFD_CONFIG_FILE" 2>/dev/null || stat -f %m "$AWSCONFD_CONFIG_FILE")
sleep 1.1
"$BIN" build --quiet
mtime2=$(stat -c %Y "$AWSCONFD_CONFIG_FILE" 2>/dev/null || stat -f %m "$AWSCONFD_CONFIG_FILE")
assert_eq "idempotency: second build does not change output mtime" "$mtime1" "$mtime2"

setup_case "build_deterministic"
"$BIN" init -y >/dev/null 2>&1
cat > "$CONFIG_D/00-defaults.conf" << 'EOF'
[default]
region = eu-west-2
EOF
"$BIN" build --quiet
cp "$AWSCONFD_CONFIG_FILE" "${_case_dir}/first.txt"
rm -f "$AWSCONFD_CONFIG_FILE"
"$BIN" build --quiet
cmp -s "${_case_dir}/first.txt" "$AWSCONFD_CONFIG_FILE" && pass "determinism: rebuild from same input is byte-identical" || fail "determinism: rebuild from same input is byte-identical"

setup_case "build_nested_settings"
"$BIN" init -y >/dev/null 2>&1
cat > "$CONFIG_D/20-p.conf" << 'EOF'
[profile withs3]
region = eu-west-2
s3 =
    max_concurrent_requests = 20
    max_queue_size = 10000
EOF
"$BIN" build --quiet
out="$(cat "$AWSCONFD_CONFIG_FILE")"
assert_contains "nested s3 block passed through verbatim" "$out" "max_concurrent_requests = 20"

setup_case "build_disabled_and_dotfiles_excluded"
"$BIN" init -y >/dev/null 2>&1
cat > "$CONFIG_D/20-p.conf" << 'EOF'
[profile keepme]
region = eu-west-2
EOF
cat > "$CONFIG_D/21-off.conf.disabled" << 'EOF'
[profile excluded]
region = eu-west-2
EOF
printf 'junk' > "$CONFIG_D/.hidden"
"$BIN" build --quiet
out="$(cat "$AWSCONFD_CONFIG_FILE")"
if [[ "$out" == *"[profile excluded]"* ]]; then
    fail "*.conf.disabled excluded from build"
else
    pass "*.conf.disabled excluded from build"
fi

setup_case "build_dry_run_writes_nothing"
"$BIN" init -y >/dev/null 2>&1
cat > "$CONFIG_D/20-p.conf" << 'EOF'
[profile p]
region = eu-west-2
EOF
rm -f "$AWSCONFD_CONFIG_FILE"
dry_out="$("$BIN" build --dry-run --quiet)"
assert_true "--dry-run writes nothing" "$([[ ! -f $AWSCONFD_CONFIG_FILE ]] && echo 0 || echo 1)"
assert_contains "--dry-run prints assembled content" "$dry_out" "[profile p]"

setup_case "build_quiet_after_subcommand"
"$BIN" init -y >/dev/null 2>&1
"$BIN" build --quiet
assert_exit "build --quiet (flag AFTER subcommand, A6.1 regression) exits 0" "0" "$?"

# =============================================================================
section "Validation"
# =============================================================================

setup_case "validate_dup_profile_blocks"
"$BIN" init -y >/dev/null 2>&1
cat > "$CONFIG_D/20-a.conf" << 'EOF'
[profile dup]
region = eu-west-2
EOF
cat > "$CONFIG_D/21-b.conf" << 'EOF'
[profile dup]
region = us-east-1
EOF
cp "$AWSCONFD_CONFIG_FILE" "${_case_dir}/before.txt"
"$BIN" build --quiet 2>"${_case_dir}/err.txt"
rc=$?
assert_exit "B2 duplicate profile: build exits 3" "3" "$rc"
assert_contains "B2 message present" "$(cat "${_case_dir}/err.txt")" "B2"
cmp -s "${_case_dir}/before.txt" "$AWSCONFD_CONFIG_FILE" && pass "B2 failure leaves output file byte-unchanged" || fail "B2 failure leaves output file byte-unchanged"

setup_case "validate_b4_missing_sso_session"
"$BIN" init -y >/dev/null 2>&1
cat > "$CONFIG_D/20-a.conf" << 'EOF'
[profile orphan]
sso_session = ghost
sso_account_id = 111122223333
sso_role_name = Foo
region = eu-west-2
EOF
err="$("$BIN" build --quiet 2>&1)"
rc=$?
assert_exit "B4 missing sso-session: exit 3" "3" "$rc"
assert_contains "B4 message present" "$err" "B4"

setup_case "validate_b5_missing_account_id"
"$BIN" init -y >/dev/null 2>&1
"$BIN" add-sso personal --start-url https://d-1.awsapps.com/start --sso-region eu-west-2 --yes --non-interactive >/dev/null 2>&1
cat > "$CONFIG_D/20-a.conf" << 'EOF'
[profile incomplete]
sso_session = personal
sso_role_name = Foo
region = eu-west-2
EOF
err="$("$BIN" build --quiet 2>&1)"
assert_contains "B5 missing sso_account_id" "$err" "B5"

setup_case "validate_b6_legacy_and_modern"
"$BIN" init -y >/dev/null 2>&1
"$BIN" add-sso personal --start-url https://d-1.awsapps.com/start --sso-region eu-west-2 --yes --non-interactive >/dev/null 2>&1
cat > "$CONFIG_D/20-a.conf" << 'EOF'
[profile mixed]
sso_session = personal
sso_account_id = 111122223333
sso_role_name = Foo
sso_start_url = https://legacy.example.com/start
region = eu-west-2
EOF
err="$("$BIN" build --quiet 2>&1)"
assert_contains "B6 both sso_session and sso_start_url" "$err" "B6"

setup_case "validate_b7_role_arn_no_source"
"$BIN" init -y >/dev/null 2>&1
cat > "$CONFIG_D/20-a.conf" << 'EOF'
[profile assumed]
role_arn = arn:aws:iam::111122223333:role/Foo
region = eu-west-2
EOF
err="$("$BIN" build --quiet 2>&1)"
assert_contains "B7 role_arn without source_profile/credential_source" "$err" "B7"

setup_case "validate_b8_undefined_source_profile"
"$BIN" init -y >/dev/null 2>&1
cat > "$CONFIG_D/20-a.conf" << 'EOF'
[profile assumed]
role_arn = arn:aws:iam::111122223333:role/Foo
source_profile = doesnotexist
region = eu-west-2
EOF
err="$("$BIN" build --quiet 2>&1)"
assert_contains "B8 undefined source_profile" "$err" "B8"

setup_case "validate_b9_overlap"
"$BIN" init -y >/dev/null 2>&1
cat >> "$XDG_CONFIG_HOME/awsconfd/scheme.conf" << 'EOF'
20-29 = personal
25-35 = other
EOF
err="$("$BIN" doctor 2>&1)"
assert_contains "B9 overlapping ranges" "$err" "B9"

setup_case "validate_b10_strict"
"$BIN" init -y >/dev/null 2>&1
cat > "$CONFIG_D/77-oor.conf" << 'EOF'
[profile oor]
region = eu-west-2
EOF
err="$("$BIN" build --strict --quiet 2>&1)"
rc=$?
assert_exit "B10 --strict prefix outside ranges: exit 3" "3" "$rc"
assert_contains "B10 message present" "$err" "B10"

setup_case "validate_w2_nonstrict"
"$BIN" init -y >/dev/null 2>&1
cat > "$CONFIG_D/77-oor.conf" << 'EOF'
[profile oor]
region = eu-west-2
EOF
err="$("$BIN" build --quiet 2>&1)"
rc=$?
assert_exit "W2 non-strict prefix outside ranges: build exit 0 (warnings don't block)" "0" "$rc"
doctor_err="$("$BIN" doctor 2>&1)"
assert_contains "W2 message present (doctor, which reports advisory rules)" "$doctor_err" "W2"

setup_case "validate_w1_bad_name"
"$BIN" init -y >/dev/null 2>&1
cat > "$CONFIG_D/notnumbered.conf" << 'EOF'
[profile p]
region = eu-west-2
EOF
err="$("$BIN" doctor 2>&1)"
assert_contains "W1 non-standard fragment name" "$err" "W1"

setup_case "validate_w4_unknown_section"
"$BIN" init -y >/dev/null 2>&1
cat > "$CONFIG_D/50-x.conf" << 'EOF'
[widgets something]
foo = bar
EOF
err="$("$BIN" doctor 2>&1)"
assert_contains "W4 unrecognised section type warned" "$err" "W4"

setup_case "validate_strict_no_scheme_is_usage_error"
"$BIN" init -y >/dev/null 2>&1
rm -f "$XDG_CONFIG_HOME/awsconfd/scheme.conf"
"$BIN" build --strict --quiet 2>/dev/null
assert_exit "--strict with no scheme.conf is a usage error (exit 2)" "2" "$?"

# =============================================================================
section "Init"
# =============================================================================

setup_case "init_import_hand_written"
mkdir -p "$(dirname "$AWSCONFD_CONFIG_FILE")"
cat > "$AWSCONFD_CONFIG_FILE" << 'EOF'
[default]
region = us-west-2

[profile handwritten]
region = eu-central-1
EOF
"$BIN" init -y >/dev/null 2>&1
cmp -s "${AWSCONFD_CONFIG_FILE}.awsconfd-backup.1" <(printf '[default]\nregion = us-west-2\n\n[profile handwritten]\nregion = eu-central-1\n') && pass "backup byte-identical to original" || fail "backup byte-identical to original"
assert_true "99-imported.conf created" "$([[ -f "$(dirname "$AWSCONFD_CONFIG_FILE")/config.d/99-imported.conf" ]] && echo 0 || echo 1)"
sections_after=$(grep -c '^\[' "$AWSCONFD_CONFIG_FILE")
assert_eq "rebuilt config has same section count as original" "2" "$sections_after"

setup_case "init_no_import"
mkdir -p "$(dirname "$AWSCONFD_CONFIG_FILE")"
cat > "$AWSCONFD_CONFIG_FILE" << 'EOF'
[default]
region = us-west-2
EOF
"$BIN" init --no-import -y >/dev/null 2>&1
assert_true "backup taken under --no-import" "$([[ -f "${AWSCONFD_CONFIG_FILE}.awsconfd-backup.1" ]] && echo 0 || echo 1)"
assert_true "no 99-imported.conf under --no-import" "$([[ ! -f "$(dirname "$AWSCONFD_CONFIG_FILE")/config.d/99-imported.conf" ]] && echo 0 || echo 1)"

setup_case "init_idempotent"
"$BIN" init -y >/dev/null 2>&1
sum_before=$(cksum < "$CONFIG_D/00-defaults.conf")
"$BIN" init -y >/dev/null 2>&1
sum_after=$(cksum < "$CONFIG_D/00-defaults.conf")
assert_eq "re-running init overwrites nothing in 00-defaults.conf" "$sum_before" "$sum_after"

setup_case "init_backup_numbering"
for i in 1 2 3; do
    mkdir -p "$(dirname "$AWSCONFD_CONFIG_FILE")"
    printf '[profile run%s]\nregion = us-west-2\n' "$i" > "$AWSCONFD_CONFIG_FILE"
    rm -rf "$CONFIG_D"
    "$BIN" init -y >/dev/null 2>&1
done
n=0
for b in "${AWSCONFD_CONFIG_FILE}".awsconfd-backup.*; do [[ -f $b ]] && n=$((n+1)); done
assert_eq "three successive inits produce three numbered backups" "3" "$n"

# =============================================================================
section "Scheme"
# =============================================================================

setup_case "scheme_range_forms"
"$BIN" init -y >/dev/null 2>&1
cat >> "$XDG_CONFIG_HOME/awsconfd/scheme.conf" << 'EOF'
2x    = personal
30-39 = customer-a
55    = one-off
EOF
cat > "$CONFIG_D/25-p.conf" << 'EOF'
[profile p25]
region = eu-west-2
EOF
cat > "$CONFIG_D/35-c.conf" << 'EOF'
[profile p35]
region = eu-west-2
EOF
cat > "$CONFIG_D/55-o.conf" << 'EOF'
[profile p55]
region = eu-west-2
EOF
err="$("$BIN" doctor 2>&1)"
if [[ "$err" == *"W2"* ]]; then
    fail "2x / NN-MM / NN range forms all parse without W2 false positives" "$err"
else
    pass "2x / NN-MM / NN range forms all parse without W2 false positives"
fi

setup_case "scheme_label_allocation"
"$BIN" init -y >/dev/null 2>&1
cat >> "$XDG_CONFIG_HOME/awsconfd/scheme.conf" << 'EOF'
2x = personal
EOF
"$BIN" add-sso personal --start-url https://d-1.awsapps.com/start --sso-region eu-west-2 --yes --non-interactive >/dev/null 2>&1
"$BIN" add-profile p1 --type sso --sso-session personal --sso-account-id 111122223333 --sso-role-name Foo --region eu-west-2 --label personal --yes --non-interactive >/dev/null 2>&1
assert_true "first allocation picks 20" "$([[ -f "$CONFIG_D/20-p1.conf" ]] && echo 0 || echo 1)"
"$BIN" add-profile p2 --type sso --sso-session personal --sso-account-id 111122223333 --sso-role-name Bar --region eu-west-2 --label personal --yes --non-interactive >/dev/null 2>&1
assert_true "second allocation picks lowest free (21)" "$([[ -f "$CONFIG_D/21-p2.conf" ]] && echo 0 || echo 1)"

# =============================================================================
section "add-sso / add-profile (section-update primitive in practice)"
# =============================================================================

setup_case "addsso_create_and_update"
"$BIN" init -y >/dev/null 2>&1
"$BIN" add-sso personal --start-url https://d-1.awsapps.com/start --sso-region eu-west-2 --yes --non-interactive >/dev/null 2>&1
out1="$(cat "$CONFIG_D/10-sso.conf")"
assert_contains "add-sso created session" "$out1" "sso_region = eu-west-2"
"$BIN" add-sso personal --start-url https://d-1.awsapps.com/start --sso-region us-east-1 --yes --non-interactive >/dev/null 2>&1
out2="$(cat "$CONFIG_D/10-sso.conf")"
assert_contains "add-sso update changes region" "$out2" "sso_region = us-east-1"
count=$(grep -c '^\[sso-session personal\]' "$CONFIG_D/10-sso.conf")
assert_eq "add-sso update does not duplicate the section" "1" "$count"

setup_case "addprofile_all_types"
"$BIN" init -y >/dev/null 2>&1
"$BIN" add-sso personal --start-url https://d-1.awsapps.com/start --sso-region eu-west-2 --yes --non-interactive >/dev/null 2>&1
"$BIN" add-profile p-sso --type sso --sso-session personal --sso-account-id 111122223333 --sso-role-name Foo --region eu-west-2 --file 20-sso.conf --yes --non-interactive >/dev/null 2>&1
assert_exit "sso profile created" "0" "$?"
"$BIN" add-profile p-assume --type assume-role --role-arn arn:aws:iam::444455556666:role/Bar --source-profile p-sso --region us-east-1 --file 30-assume.conf --yes --non-interactive >/dev/null 2>&1
assert_exit "assume-role profile created" "0" "$?"
"$BIN" add-profile p-static --type static --region eu-west-1 --file 40-static.conf --yes --non-interactive >/dev/null 2>&1
assert_exit "static profile created" "0" "$?"
static_out="$(cat "$CONFIG_D/40-static.conf")"
if [[ "$static_out" == *"aws_access_key"* || "$static_out" == *"secret"* ]]; then
    fail "static profile never writes credential keys"
else
    pass "static profile never writes credential keys"
fi
doctor_err="$("$BIN" doctor 2>&1)"
if [[ "$doctor_err" == *"ERROR"* ]]; then
    fail "doctor clean after all profile types added" "$doctor_err"
else
    pass "doctor clean after all profile types added"
fi

# =============================================================================
section "apply --spec"
# =============================================================================

setup_case "apply_spec_reproduce"
"$BIN" init -y >/dev/null 2>&1
rm -f "$XDG_CONFIG_HOME/awsconfd/scheme.conf"
cat > "${_case_dir}/spec.ini" << 'EOF'
[awsconfd]
version = 1
strict  = false

[awsconfd:scheme]
00    = defaults
10    = sso-sessions
2x    = personal

[awsconfd:layout]
default                = 00-defaults.conf
sso-session personal   = 10-sso.conf
profile personal-admin = 20-personal-admin.conf

[default]
output = json

[sso-session personal]
sso_start_url = https://d-1.awsapps.com/start
sso_region    = eu-west-2

[profile personal-admin]
sso_session    = personal
sso_account_id = 111122223333
sso_role_name  = AdministratorAccess
region         = eu-west-2
EOF
"$BIN" apply --spec "${_case_dir}/spec.ini" >/dev/null 2>&1
assert_exit "apply --spec succeeds" "0" "$?"
assert_true "layout-named fragments created" "$([[ -f "$CONFIG_D/20-personal-admin.conf" ]] && echo 0 || echo 1)"
reapply_out="$("$BIN" apply --spec "${_case_dir}/spec.ini" 2>&1)"
assert_contains "re-applying reports SKIP for existing sections" "$reapply_out" "SKIP"

setup_case "apply_spec_stdin"
"$BIN" init -y >/dev/null 2>&1
rm -f "$XDG_CONFIG_HOME/awsconfd/scheme.conf"
cat "${_case_dir}/../apply_spec_reproduce/spec.ini" 2>/dev/null | "$BIN" apply --spec - >/dev/null 2>&1 || {
cat > "${_case_dir}/spec.ini" << 'EOF'
[awsconfd]
version = 1

[awsconfd:layout]
default = 00-defaults.conf

[default]
output = json
EOF
"$BIN" apply --spec - < "${_case_dir}/spec.ini" >/dev/null 2>&1
}
assert_exit "apply --spec - reads stdin" "0" "$?"

# =============================================================================
section "Watch"
# =============================================================================

setup_case "watch_no_init_system"
"$BIN" init -y >/dev/null 2>&1

# Force "no init system" detection regardless of the host's real session
# state. On a machine with a live systemd --user session, XDG_RUNTIME_DIR/
# systemd/private exists and is checked *before* is-system-running, so
# without this the test exercises the real systemd install path against
# the real user manager and fails (unit written under the test's fake
# XDG_CONFIG_HOME is invisible to the already-running manager).
#
# B6.7 names _systemctl/_launchctl as the intended stub points, but those
# only help when the script is sourced; here it's exec'd as a subprocess,
# so a PATH shim is the black-box equivalent.
_fakebin="${_case_dir}/fakebin"
mkdir -p "$_fakebin"
cat > "$_fakebin/systemctl" << 'EOF'
#!/bin/sh
# Stub: always behave like a non-live/offline user session.
echo offline
exit 1
EOF
chmod +x "$_fakebin/systemctl"

out="$(PATH="${_fakebin}:${PATH}" XDG_RUNTIME_DIR="${_case_dir}/no-runtime-dir" "$BIN" watch --install 2>&1)"
rc=$?
assert_exit "watch --install with no systemd/launchd exits 0" "0" "$rc"
assert_contains "watch --install prints Layer-3 recommendation" "$out" "hook"

# =============================================================================
section "Status"
# =============================================================================

setup_case "status_stale_after_touch"
"$BIN" init -y >/dev/null 2>&1
"$BIN" status --check
assert_exit "status --check current after init" "0" "$?"
sleep 1.1
touch "$CONFIG_D/00-defaults.conf"
"$BIN" status --check
assert_exit "status --check stale after touch" "4" "$?"
sleep 1.1
"$BIN" build --quiet
"$BIN" status --check
assert_exit "status --check current after rebuild" "0" "$?"
sleep 1.1
rm -f "$CONFIG_D/00-defaults.conf"
"$BIN" status --check
assert_exit "status --check stale after fragment deletion (dir mtime)" "4" "$?"

# =============================================================================
section "enable / disable"
# =============================================================================

setup_case "enable_disable_variants"
"$BIN" init -y >/dev/null 2>&1
cat > "$CONFIG_D/20-a.conf" << 'EOF'
[profile a]
region = eu-west-2
EOF
"$BIN" build --quiet >/dev/null 2>&1
"$BIN" disable 20 >/dev/null 2>&1
assert_true "disable resolves bare prefix" "$([[ -f "$CONFIG_D/20-a.conf.disabled" ]] && echo 0 || echo 1)"
"$BIN" enable 20-a.conf.disabled >/dev/null 2>&1
assert_true "enable resolves full disabled filename" "$([[ -f "$CONFIG_D/20-a.conf" ]] && echo 0 || echo 1)"

# =============================================================================
printf '\n=== Summary ===\n'
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
    printf 'Failed:\n'
    for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
    exit 1
fi
exit 0
