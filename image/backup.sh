#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

# This file is sourced by run.sh after service-user normalization. Keep it
# definition-only so sourcing it cannot create, remove, or publish backup data.

# Administrators can choose backup paths, so commands use the configured openldap
# identity without inheriting the entrypoint's supplementary groups or capabilities.
# An explicit LDAP_OPENLDAP_UID=0 mapping is still privileged by definition; this
# boundary prevents accidental root inheritance rather than overriding that choice.
function run_as_openldap() {
  /usr/bin/setpriv \
    --reuid openldap \
    --regid openldap \
    --clear-groups \
    --inh-caps=-all \
    --ambient-caps=-all \
    --no-new-privs \
    -- "$@"
}

ldap_backup_temporary_directory_marker='.docker-openldap-backup-tmp'
# Long sleeps would preserve a stale assumption after a timezone or manual clock
# change. Five minutes keeps reevaluation bounded without returning to 10-second
# process polling for the entire day.
ldap_backup_schedule_max_sleep_seconds=300
# These globals carry persisted backup state between run.sh lifecycle calls.
initial_backup_pending_marker=/var/lib/ldap/.initial-backup-pending
initial_backup_pending=false
is_syncrepl_consumer=false

function mark_initial_ldap_backup_pending() {
  local replication_role=$1
  local existing_entry

  # A consumer cannot produce a complete initial export while syncrepl is still
  # starting. Writers persist intent before run.sh writes its initialized marker,
  # so a later startup failure cannot silently skip the final backup.
  [[ $replication_role != consumer ]] || return 0

  # Let mkdir perform the atomic reservation first. If an earlier attempt already
  # reserved it, adopt only an empty real directory: the later cleanup uses rmdir
  # and therefore never removes marker contents. Ownership is not provenance here
  # because run.sh intentionally reowns the persistent data volume on every start.
  # Suppress mkdir's expected EEXIST diagnostic; the checks below emit the
  # path-state-specific error when the existing marker is unsafe.
  if mkdir -m 700 -- "$initial_backup_pending_marker" 2>/dev/null; then
    return 0
  fi
  if [[ -L $initial_backup_pending_marker || ! -d $initial_backup_pending_marker ]]; then
    log ERROR "Cannot create initial backup marker [$initial_backup_pending_marker]."
    return 1
  fi
  if ! existing_entry=$(find "$initial_backup_pending_marker" -mindepth 1 -maxdepth 1 -print -quit); then
    log ERROR "Cannot inspect initial backup marker [$initial_backup_pending_marker]."
    return 1
  fi
  if [[ -n $existing_entry ]]; then
    log ERROR "Initial backup marker [$initial_backup_pending_marker] is not empty."
    return 1
  fi
  return 0
}

function load_ldap_backup_state() {
  initial_backup_pending=false
  if [[ -e $initial_backup_pending_marker || -L $initial_backup_pending_marker ]]; then
    # A directory marker lets rmdir consume only empty image-owned state and never
    # follows a file symlink in the service-writable data volume. Do not let any
    # other type mark a backup as pending.
    if [[ -L $initial_backup_pending_marker || ! -d $initial_backup_pending_marker ]]; then
      log ERROR "Initial backup marker [$initial_backup_pending_marker] is not a directory."
      return 1
    fi
    initial_backup_pending=true
  fi

  # Bootstrap variables disappear on normal restarts, so persisted olcSyncrepl is
  # the authoritative indication that this server hosts a consumer engine. Backups
  # use this conservative server-wide flag because exporting any partial replica is
  # misleading, even when another local database remains writable.
  # cn=config can load service-controlled modules while slapcat opens it. Match
  # slapd's identity so a persisted module cannot execute inside the root entrypoint.
  # Avoid grep -q: its early exit can SIGPIPE slapcat, and pipefail would then hide
  # a real match by making the condition fail.
  # Keep inspection failure nonfatal here: run.sh starts slapd from the same
  # persisted configuration before any pending initial backup can be published.
  is_syncrepl_consumer=false
  if run_as_openldap /usr/sbin/slapcat -n 0 -o ldif-wrap=no | grep -F 'olcSyncrepl:' >/dev/null; then
    is_syncrepl_consumer=true
  fi

  if [[ $initial_backup_pending == true && $is_syncrepl_consumer == true ]]; then
    # Persisted syncrepl configuration determines the server role on restart. A
    # stale marker can survive when writer config is paired with consumer data, but
    # exporting that partial replica would be misleading and retrying cannot make it valid.
    if ! rmdir -- "$initial_backup_pending_marker"; then
      log ERROR "Cannot remove stale initial backup marker [$initial_backup_pending_marker] from a syncrepl consumer."
      return 1
    fi
    initial_backup_pending=false
    log INFO "Discarding pending initial LDAP backup because the persisted configuration is a syncrepl consumer."
  fi
}

function prepare_ldap_backup_temporary_directory() {
  local temporary_directory=$1
  local marker_file="$temporary_directory/$ldap_backup_temporary_directory_marker"
  local effective_uid
  local directory_metadata
  local marker_metadata
  local existing_entry
  local invalid_entry

  effective_uid=$(id -u openldap)

  # Keep incomplete exports inside one reserved directory instead of matching a
  # filename glob in the operator-controlled backup directory. The path alone is
  # not proof of ownership, so metadata and a marker establish that cleanup may
  # treat the directory as image-managed state.
  if [[ -L $temporary_directory ||
        ( -e $temporary_directory && ! -d $temporary_directory ) ]]; then
    log ERROR "LDAP backup temporary path [$temporary_directory] is not a directory."
    return 1
  fi
  if [[ ! -d $temporary_directory ]] &&
      ! run_as_openldap mkdir -m 700 -- "$temporary_directory"; then
    log ERROR "Cannot create LDAP backup temporary directory [$temporary_directory]."
    return 1
  fi

  # A setgid backup parent can legitimately supply another group and the directory's
  # 02000 bit. Its 0700 access bits still grant that group no authority, so owner
  # UID and access mode are the safety boundary.
  if ! directory_metadata=$(stat -c '%u:%a' -- "$temporary_directory"); then
    log ERROR "Cannot inspect LDAP backup temporary directory [$temporary_directory]."
    return 1
  fi
  if [[ $directory_metadata != "$effective_uid:700" &&
        $directory_metadata != "$effective_uid:2700" ]]; then
    log ERROR "LDAP backup temporary directory [$temporary_directory] must be owned by openldap with mode 0700."
    return 1
  fi

  if [[ ! -e $marker_file && ! -L $marker_file ]]; then
    if ! existing_entry=$(find "$temporary_directory" -mindepth 1 -maxdepth 1 -print -quit); then
      log ERROR "Cannot inspect LDAP backup temporary directory [$temporary_directory]."
      return 1
    fi
    if [[ -n $existing_entry ]]; then
      log ERROR "LDAP backup temporary directory [$temporary_directory] is not an initialized private directory; refusing to remove its contents."
      return 1
    fi

    # mkdir and marker creation cannot be atomic. Adopting only an empty directory
    # recovers from interruption between them without guessing that existing data
    # belongs to this image.
    if ! run_as_openldap install -m 600 /dev/null "$marker_file"; then
      log ERROR "Cannot initialize LDAP backup temporary directory [$temporary_directory]."
      return 1
    fi
  fi

  if [[ -L $marker_file || ! -f $marker_file ]] ||
      ! marker_metadata=$(stat -c '%u:%a' -- "$marker_file") ||
      [[ $marker_metadata != "$effective_uid:600" ]]; then
    log ERROR "LDAP backup temporary directory marker [$marker_file] must be a regular file owned by openldap with mode 0600."
    return 1
  fi

  # Validate the full directory before deleting anything. A one-pass find could
  # remove valid-looking entries before discovering operator data later in its
  # traversal, turning a safe rejection into partial data loss. mktemp replaces
  # the six X characters used below with ASCII letters and digits, so any broader
  # filename is not output from this writer.
  if ! invalid_entry=$(find "$temporary_directory" \
      -regextype posix-extended \
      -mindepth 1 -maxdepth 1 \
      ! -name "$ldap_backup_temporary_directory_marker" \
      ! \( -type f \
           -uid "$effective_uid" \
           -perm 0600 \
           -regex '.*/export\.[A-Za-z0-9]{6}' \) \
      -print -quit); then
    log ERROR "Cannot inspect LDAP backup temporary directory [$temporary_directory]."
    return 1
  fi
  if [[ -n $invalid_entry ]]; then
    log ERROR "Unexpected entry [$invalid_entry] in LDAP backup temporary directory [$temporary_directory]; refusing cleanup."
    return 1
  fi

  # run.sh has only one backup writer: the initial export completes before the
  # periodic worker is started. Cleaning the validated exporter namespace on every
  # call is therefore safe and removes an export left by SIGKILL or a container crash.
  if ! run_as_openldap find "$temporary_directory" \
      -regextype posix-extended \
      -mindepth 1 -maxdepth 1 \
      -type f -regex '.*/export\.[A-Za-z0-9]{6}' -delete; then
    log ERROR "Cannot clean LDAP backup temporary directory [$temporary_directory]."
    return 1
  fi
}

function recover_interrupted_ldap_backup() {
  local backup_file=$1
  local backup_directory
  local backup_name
  local temporary_directory

  [[ -n $backup_file ]] || return 0

  backup_directory=$(dirname -- "$backup_file")
  backup_name=$(basename -- "$backup_file")
  temporary_directory="$backup_directory/.${backup_name}.tmp"
  # Do not create backup state when no export has used this destination. Recovery
  # runs even with daily scheduling disabled only to reclaim a validated export
  # that an earlier writer left behind.
  [[ -e $temporary_directory || -L $temporary_directory ]] || return 0

  if ! prepare_ldap_backup_temporary_directory "$temporary_directory"; then
    # Disabling daily backups must not turn an unsafe or inaccessible temporary
    # path into an LDAP startup failure. Leave it untouched; an enabled scheduler
    # revalidates the same path strictly before it starts.
    log WARN "Cannot recover interrupted LDAP backup state at [$temporary_directory]; leaving it unchanged."
  fi
  return 0
}

function check_ldap_backup_directory() {
  local backup_file=$1
  local backup_directory
  local backup_name
  local temporary_directory
  local write_probe

  backup_directory=$(dirname -- "$backup_file")
  backup_name=$(basename -- "$backup_file")
  temporary_directory="$backup_directory/.${backup_name}.tmp"
  # Probe with the same identity and parent directory used for publication. The
  # destination itself is deliberately untouched: it may be a symlink, and a new
  # consumer must not expose an empty file before its first refresh completes.
  if ! write_probe=$(run_as_openldap \
      mktemp -- "$backup_directory/.ldap-backup-write-test.XXXXXX"); then
    log ERROR "LDAP backup directory [$backup_directory] is not writable by openldap."
    return 1
  fi
  if ! run_as_openldap rm -f -- "$write_probe"; then
    log ERROR "Cannot remove LDAP backup directory probe [$write_probe]."
    return 1
  fi
  # Scheduled backups may not run for almost a day. Reclaim an abandoned export at
  # startup instead of retaining its database-sized allocation until then.
  prepare_ldap_backup_temporary_directory "$temporary_directory" || return

  # Probe inside the private directory during startup validation. Use the export
  # namespace so interruption here leaves an entry the next preparation recognizes
  # and can reclaim, rather than permanently poisoning the directory.
  if ! write_probe=$(run_as_openldap mktemp -- "$temporary_directory/export.XXXXXX"); then
    log ERROR "LDAP backup temporary directory [$temporary_directory] is not writable by openldap."
    return 1
  fi
  if ! run_as_openldap rm -f -- "$write_probe"; then
    log ERROR "Cannot remove LDAP backup temporary directory probe [$write_probe]."
    return 1
  fi
}

function write_ldap_backup() {
  local backup_file=$1
  local backup_directory
  local backup_name
  local temporary_directory
  local temporary_file

  backup_directory=$(dirname -- "$backup_file")
  backup_name=$(basename -- "$backup_file")
  temporary_directory="$backup_directory/.${backup_name}.tmp"
  prepare_ldap_backup_temporary_directory "$temporary_directory" || return
  if ! temporary_file=$(run_as_openldap \
      mktemp -- "$temporary_directory/export.XXXXXX"); then
    return 1
  fi

  # The derived directory is normally on the destination filesystem, but a nested
  # mount can put it elsewhere. GNU mv otherwise handles EXDEV by copying, exposing
  # a partial destination and discarding the last good backup. --no-copy turns that
  # layout into a safe failure. -T replaces a destination symlink itself instead of
  # writing through it. Publication uses the configured openldap identity because
  # that account owns both the temporary export and the public directory entry.
  if run_as_openldap /usr/sbin/slapcat -n 1 -l "$temporary_file" &&
      run_as_openldap mv --no-copy -fT -- "$temporary_file" "$backup_file"; then
    return 0
  fi

  if ! run_as_openldap rm -f -- "$temporary_file"; then
    log WARN "Cannot remove incomplete LDAP backup [$temporary_file]."
  fi
  return 1
}

function create_initial_ldap_backup() {
  [[ $initial_backup_pending == true ]] || return 0
  # Do not derive a relative ./..tmp path from an empty destination. Preserve the
  # pending marker so a later startup can fulfill the backup once a path is set.
  [[ -n ${LDAP_BACKUP_FILE:-} ]] || return 0

  log INFO "Creating LDAP backup at [$LDAP_BACKUP_FILE]..."
  if write_ldap_backup "$LDAP_BACKUP_FILE"; then
    if ! rmdir -- "$initial_backup_pending_marker"; then
      # The export is usable. Keep startup behavior non-fatal as before; a marker
      # that remains causes a harmless refresh on the next start.
      log WARN "Cannot remove initial backup marker [$initial_backup_pending_marker]."
    fi
  else
    # Initial backup failures have historically not blocked LDAP startup. Leave
    # the marker so a later start retries instead of silently abandoning the backup.
    log WARN "Cannot create initial LDAP backup at [$LDAP_BACKUP_FILE]; it will be retried on the next start."
  fi

  # Initial backup is best-effort by contract; the marker carries retry state.
  return 0
}

function ldap_backup_seconds_until_schedule() {
  local current_time=$1
  local allow_current_minute=$2
  local current_hour=${current_time%%:*}
  local current_minute_and_second=${current_time#*:}
  local current_minute=${current_minute_and_second%%:*}
  local current_second=${current_minute_and_second#*:}
  local scheduled_hour=${LDAP_BACKUP_TIME%%:*}
  local scheduled_minute=${LDAP_BACKUP_TIME#*:}
  local current_total_seconds
  local scheduled_total_seconds
  local seconds_until_schedule

  # configure_ldap_backup validates the schedule, and callers obtain current_time
  # from date. Keeping this calculation in shell avoids GNU date normalizing an
  # absent or repeated local time differently across DST implementations.
  current_total_seconds=$((10#$current_hour * 3600 + 10#$current_minute * 60 + 10#$current_second))
  scheduled_total_seconds=$((10#$scheduled_hour * 3600 + 10#$scheduled_minute * 60))

  if [[ $allow_current_minute == true &&
        $current_hour == "$scheduled_hour" &&
        $current_minute == "$scheduled_minute" ]]; then
    printf '0\n'
    return 0
  fi

  seconds_until_schedule=$((scheduled_total_seconds - current_total_seconds))
  if (( seconds_until_schedule <= 0 )); then
    # This modulo-day value is only an estimate for the next bounded sleep. The
    # waiter repeatedly reads the wall clock, so DST and clock changes are not
    # baked into a day-long sleep interval.
    seconds_until_schedule=$((seconds_until_schedule + 24 * 60 * 60))
  fi
  printf '%d\n' "$seconds_until_schedule"
}

function wait_for_ldap_backup_schedule() {
  # Return the selected civil date by reference. Command substitution would run
  # this long-lived waiter in a subshell and make its logging/output contract easy
  # to break when more diagnostics are added.
  local -n scheduled_date_result=$1
  local last_backup_date=${2:-}
  local allow_current_minute
  local current_schedule_state
  local current_date
  local current_time
  local current_utc_offset
  local current_epoch_seconds
  local expected_schedule_utc_offset=
  local expected_schedule_epoch_seconds=
  local seconds_until_schedule
  local sleep_seconds

  while true; do
    if ! current_schedule_state=$(date '+%F %H:%M:%S %z %s'); then
      log ERROR "Cannot read the current time required for the LDAP backup schedule."
      return 1
    fi
    read -r current_date current_time current_utc_offset current_epoch_seconds \
      <<< "$current_schedule_state"

    # Suppress the entire civil date that already ran, not only its first matching
    # minute. Otherwise the repeated hour at the end of DST can publish two backups
    # for one day. A new date becomes eligible even after the previous export ran long.
    allow_current_minute=true
    if [[ -n $last_backup_date && $current_date == "$last_backup_date" ]]; then
      allow_current_minute=false
    fi

    seconds_until_schedule=$(ldap_backup_seconds_until_schedule \
      "$current_time" "$allow_current_minute") || return
    if (( seconds_until_schedule == 0 )); then
      scheduled_date_result=$current_date
      return 0
    fi

    if [[ $allow_current_minute == true &&
          -n $expected_schedule_epoch_seconds &&
          $current_utc_offset == "$expected_schedule_utc_offset" ]] &&
        (( current_epoch_seconds >= expected_schedule_epoch_seconds )); then
      # Count a recovered occurrence on the date when it is noticed. This permits
      # one immediate catch-up after a long pause without also running again later
      # on the same civil date.
      # shellcheck disable=SC2034  # The nameref assignment updates the caller's result.
      scheduled_date_result=$current_date
      return 0
    fi

    sleep_seconds=$seconds_until_schedule
    if (( sleep_seconds > ldap_backup_schedule_max_sleep_seconds )); then
      sleep_seconds=$ldap_backup_schedule_max_sleep_seconds
    fi
    # Remember the occurrence calculated from this observation. A delayed wake or
    # same-offset clock jump can cross that deadline; an offset change invalidates
    # the relative calculation so DST keeps its existing civil-time behavior.
    expected_schedule_utc_offset=$current_utc_offset
    expected_schedule_epoch_seconds=$((current_epoch_seconds + seconds_until_schedule))
    sleep "${sleep_seconds}s" || return
  done
}

function backup_ldap() {
  if [[ $is_syncrepl_consumer == true ]]; then
    log INFO "Waiting for the initial syncrepl refresh before enabling periodic LDAP backups..."
    # The worker starts immediately before the final slapd process. Wait for
    # its local socket so startup connection failures are not mistaken for an
    # incomplete syncrepl refresh.
    while ! ldapwhoami -Q -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1; do
      sleep 1s
    done

    local backup_suffix
    local backup_suffix_ldif
    # Bootstrap variables may be omitted or changed on a normal restart, so
    # use the suffix that is authoritative in the persisted configuration.
    if ! backup_suffix_ldif=$(
      ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
        -b 'olcDatabase={1}mdb,cn=config' -s base '(objectClass=*)' olcSuffix |
        sed -n '/^olcSuffix: /p; /^olcSuffix:: /p'
    ); then
      log ERROR "Cannot determine the persisted MDB suffix required to verify the initial syncrepl refresh."
      return 1
    fi
    case "$backup_suffix_ldif" in
      'olcSuffix: '*) backup_suffix=${backup_suffix_ldif#olcSuffix: } ;;
      'olcSuffix:: '*)
        # LDIF base64-encodes values that are not safe ASCII. Decode that
        # representation so non-ASCII organization DNs remain valid search bases.
        if ! backup_suffix=$(printf '%s' "${backup_suffix_ldif#olcSuffix:: }" | base64 -d); then
          log ERROR "Cannot decode the persisted MDB suffix required to verify the initial syncrepl refresh."
          return 1
        fi
        ;;
      *)
        log ERROR "Cannot determine the persisted MDB suffix required to verify the initial syncrepl refresh."
        return 1
        ;;
    esac

    # Initial-refresh entries carry no synchronization cookie. OpenLDAP writes
    # contextCSN after the refresh completes, so its presence distinguishes a
    # coherent replica from an empty or partially populated database. Query
    # only the suffix entry; repeatedly exporting the database makes startup
    # cost grow with the number of entries already received.
    while true; do
      local refresh_state
      local refresh_status
      if refresh_state=$(
        ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// \
          -b "$backup_suffix" -s base '(contextCSN=*)' contextCSN 2>&1
      ); then
        if [[ $refresh_state == contextCSN:\ * || $refresh_state == *$'\ncontextCSN: '* ]]; then
          break
        fi
      else
        refresh_status=$?
        # LDAP result 32 means that syncrepl has not created the suffix entry
        # yet. Other errors are configuration failures, not a reason to wait
        # forever while silently disabling backups.
        if (( refresh_status != 32 )); then
          log ERROR "Cannot query syncrepl refresh state for [$backup_suffix]: $refresh_state"
          return 1
        fi
      fi
      sleep 10s
    done
    log INFO "Initial syncrepl refresh completed; enabling periodic LDAP backups."
  fi

  # De-duplication is deliberately process-local. A container restart starts a
  # new scheduler; persisting dates would promise exactly-once behavior across
  # restarts, which is outside this daily best-effort backup contract.
  local last_backup_date=
  local scheduled_date
  while true; do
    wait_for_ldap_backup_schedule scheduled_date "$last_backup_date" || return
    # Reserve this scheduled occurrence before exporting. Failed exports keep the
    # historical once-per-day retry behavior instead of looping for the whole minute.
    last_backup_date=$scheduled_date
    log INFO "Creating periodic LDAP backup at [$LDAP_BACKUP_FILE]..."
    # A later filesystem or export failure must not stop LDAP. Keep the worker
    # alive so it can try again at the next scheduled time.
    if ! write_ldap_backup "$LDAP_BACKUP_FILE"; then
      log WARN "Cannot create periodic LDAP backup at [$LDAP_BACKUP_FILE]."
    fi
    # Recalculate from the completion time instead of adding 23 hours. A large
    # export may finish after that fixed delay would have passed tomorrow's
    # configured minute, which otherwise defers the next backup for another day.
  done
}

function configure_ldap_backup() {
  [[ -n ${LDAP_BACKUP_TIME:-} ]] || return 0

  if [[ -z ${LDAP_BACKUP_FILE:-} ]]; then
    log ERROR "LDAP_BACKUP_FILE variable is not set!"
    return 1
  fi

  log BOX "Configuring LDAP backup task to run daily: time=[${LDAP_BACKUP_TIME}] file=[$LDAP_BACKUP_FILE]..."
  if [[ ! $LDAP_BACKUP_TIME =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    log ERROR "The configured value [$LDAP_BACKUP_TIME] for LDAP_BACKUP_TIME is not in the expected 24-hour format [hh:mm]!"
    return 1
  fi

  # A fixed directory-permission problem will not improve by schedule time, so
  # report it before the container becomes ready.
  check_ldap_backup_directory "$LDAP_BACKUP_FILE" || return 1

  backup_ldap &
}
