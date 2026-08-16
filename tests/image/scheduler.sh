#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

# deterministic backup scheduler checks.
# This file is sourced by test-image.sh and intentionally shares its fixtures,
# helpers, and cleanup trap so scenario boundaries do not create extra Docker
# resources or alter lifecycle ordering.

# shellcheck disable=SC2154,SC2329  # Globals and invocation are supplied by test-image.sh.
function test_backup_scheduler() {
test_phase "Checking backup scheduler logic"

# Exercise schedule arithmetic inside the image without waiting for wall-clock
# time. The 03:05 case models an export that started at 02:00 and ran for 65
# minutes: the next backup must still target the following 02:00, not add a
# fixed 23-hour delay and miss that day.
docker run --rm --entrypoint bash \
  --env LDAP_BACKUP_TIME=02:00 \
  "$image_name" -c '
    set -euo pipefail
    source /opt/backup.sh

    function assert_schedule_delay() {
      local current_time=$1
      local allow_current_minute=$2
      local expected_delay=$3
      local actual_delay

      actual_delay=$(ldap_backup_seconds_until_schedule \
        "$current_time" "$allow_current_minute")
      if [[ $actual_delay != "$expected_delay" ]]; then
        echo "At [$current_time], expected [$expected_delay] seconds until the next backup but got [$actual_delay]." >&2
        return 1
      fi
    }

    assert_schedule_delay 01:59:30 true 30
    assert_schedule_delay 02:00:30 true 0
    # A completed backup must not start again during the minute that launched it.
    assert_schedule_delay 02:00:30 false 86370
    assert_schedule_delay 03:05:00 true 82500

    # Each sleep advances one fixed GNU date response. This exercises the waiter
    # without duplicating its clock semantics in the test.
    function assert_selected_schedule_date() {
      local expected_date=$1
      local last_backup_date=$2
      shift 2
      local -a mock_schedule_states=("$@")
      local mock_schedule_index=0
      local selected_schedule_date=

      function date() {
        printf "%s\n" "${mock_schedule_states[$mock_schedule_index]}"
      }
      function sleep() {
        ((mock_schedule_index += 1))
        if (( mock_schedule_index >= ${#mock_schedule_states[@]} )); then
          echo "The scheduler did not select an occurrence from the supplied clock states." >&2
          return 1
        fi
      }

      wait_for_ldap_backup_schedule selected_schedule_date "$last_backup_date"
      if [[ $selected_schedule_date != "$expected_date" ]]; then
        echo "Expected backup date [$expected_date] but selected [$selected_schedule_date]." >&2
        return 1
      fi
    }

    ldap_backup_schedule_max_sleep_seconds=1

    # A delayed wake or same-offset forward correction must recover the occurrence
    # it crossed instead of silently waiting until tomorrow.
    assert_selected_schedule_date 2026-06-01 "" \
      "2026-06-01 01:58:00 +0200 1780271880" \
      "2026-06-01 03:05:00 +0200 1780275900"

    # A changed offset is a civil-time transition, not evidence that the absent
    # spring-forward hour should receive a catch-up backup.
    assert_selected_schedule_date 2026-03-30 "" \
      "2026-03-29 01:58:00 +0100 1774745880" \
      "2026-03-29 03:05:00 +0200 1774746300" \
      "2026-03-30 02:00:00 +0200 1774828800"

    # Suppress a date that already ran even when its local hour repeats at the end
    # of DST; the next date remains eligible.
    assert_selected_schedule_date 2026-10-26 2026-10-25 \
      "2026-10-25 02:00:30 +0200 1792886430" \
      "2026-10-26 02:00:00 +0100 1792976400"

    # Exercise the worker handoff without waiting for real time. The first mocked
    # occurrence must reach the configured writer; the second wait stops the loop.
    worker_wait_count=0
    worker_write_count=0
    LDAP_BACKUP_FILE=/tmp/scheduled-backup.ldif
    is_syncrepl_consumer=false
    function wait_for_ldap_backup_schedule() {
      ((worker_wait_count += 1))
      ((worker_wait_count == 1)) || return 1
      printf -v "$1" '%s' 2026-06-01
    }
    function write_ldap_backup() {
      [[ $1 == "$LDAP_BACKUP_FILE" ]] || return 1
      ((worker_write_count += 1))
    }
    function log() {
      :
    }
    backup_ldap || true
    if ((worker_wait_count != 2 || worker_write_count != 1)); then
      echo "The periodic backup worker did not hand the scheduled occurrence to the writer." >&2
      exit 1
    fi

    # An empty destination pauses the pending initial export. It must not be
    # converted into a relative path such as ./..tmp; retaining the pending state
    # lets a later startup complete the export after a destination is configured.
    initial_backup_pending=true
    LDAP_BACKUP_FILE=
    backup_write_attempted=false
    # Record the call without touching storage. Returning failure avoids marker
    # cleanup; the log stub lets the explicit assertion report the regression.
    function write_ldap_backup() {
      backup_write_attempted=true
      return 1
    }
    function log() {
      :
    }
    create_initial_ldap_backup
    if [[ $backup_write_attempted == true ]]; then
      echo "An empty LDAP_BACKUP_FILE must not start an initial backup." >&2
      exit 1
    fi
  '
}
