#!/usr/bin/env bash

set -e
set -u

# 0 | 1 | 2
VERBOSE=0

# type TestScenario = TestDefinition[]
#
# type TestDefinition = {
#   description: string
#   command: string
#   stdin?: string[]
#   stdin_final_newline?: boolean
#   stdout?: string[]
#   stdout_final_newline?: boolean
#   stderr?: string[]
#   stderr_final_newline?: boolean
# }
#
# type TestResult = TestDefinition & {
#   status: 'success' | 'failed'
#   stdout_base64_encoded: {
#     expected: string
#     actual: string
#   }
#   stderr_base64_encoded: {
#     expected: string
#     actual: string
#   }
# }

# stdin: TestDefinition
# stdout: TestResult
function run_one()
{
    local _definition
    local _stdin
    local _stdout_expected
    local _stdout_actual
    local _stderr_expected
    local _stderr_actual
    local _status

    {
        read -r _definition
        read -r _command
        read -r _stdin
        read -r _stdout_expected
        read -r _stderr_expected
    } < <(jq -cMr '
        def encode_lines(final_newline):
            if . == null then
                ""
            elif final_newline != false then
                . | join("\n") + "\n"
            else
                . | join("\n")
            end | @base64
        ;

        .,
        (.command | @base64),
        (. as $parent | .stdin | encode_lines($parent.stdin_final_newline)),
        (. as $parent | .stdout | encode_lines($parent.stdout_final_newline)),
        (. as $parent | .stderr | encode_lines($parent.stderr_final_newline))
    ')

    _stdout_actual=$(base64 -d <<<"$_stdin" | eval "($(base64 -d <<<"$_command")) 2>/dev/null" | base64)
    _stderr_actual=$(base64 -d <<<"$_stdin" | eval "(($(base64 -d <<<"$_command")) 3>&2 2>&1 1>&3) 2>/dev/null" | base64)

    _status=success

    if [ "$_stdout_expected" != "$_stdout_actual" ]; then
        _status=failed
    fi

    if [ "$_stderr_expected" != "$_stderr_actual" ]; then
        _status=failed
    fi

    jq \
        --arg status "$_status" \
        --arg stdout_expected "$_stdout_expected" \
        --arg stdout_actual "$_stdout_actual" \
        --arg stderr_expected "$_stderr_expected" \
        --arg stderr_actual "$_stderr_actual" \
        $'. + {
            "status": $status,
            "stdout_base64_encoded": {
                "expected": $stdout_expected,
                "actual": $stdout_actual
            },
            "stderr_base64_encoded": {
                "expected": $stderr_expected,
                "actual": $stderr_actual
            }
        }' <<<"$_definition"
}

# $1: string
# stdin: TestScenario
function run_tests()
{
    local _section
    local _definition
    local _description
    local _result
    local _status

    _section=$1

    jq -cM '.[]' | while read -r _definition
    do
        _status=running
        _description=$(jq -cMr .description <<<"$_definition")
        printf ' %7s %s: %s\r' "$_status" "$_section" "$_description"

        _result=$(run_one <<<"$_definition")
        _status=$(jq -cMr .status <<<"$_result")
        printf ' %7s %s: %s\n' "$_status" "$_section" "$_description"

        if (( VERBOSE == 0 )); then
            continue
        fi

        if (( VERBOSE >= 1 )); then
            jq . <<<"$_result"
        fi

        if (( VERBOSE >= 2 )); then
            jq '{
                stdout: {
                    expected: (.stdout_base64_encoded.expected | @base64d),
                    __actual: (.stdout_base64_encoded.actual | @base64d)
                },
                stderr: {
                    expected: (.stderr_base64_encoded.expected | @base64d),
                    __actual: (.stderr_base64_encoded.actual | @base64d)
                }
            }' <<<"$_result"
        fi

        echo
    done
}

# $@: TestScenario JSON files
# stdin?: TestScenario
function main()
{
    local _path

    if ! tty -s; then
        run_tests '/dev/stdin'
    fi

    for _path in "$@"
    do
        run_tests "${_path%.json}" <"$_path"
    done
}

case "${1:-}" in
-v) VERBOSE=1; shift ;;
-vv) VERBOSE=2; shift ;;
esac

main "$@"
