#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Vegard IT GmbH (https://vegardit.com)
# SPDX-FileContributor: Sebastian Thomschke
# SPDX-License-Identifier: Apache-2.0
# SPDX-ArtifactOfProjectHomePage: https://github.com/vegardit/docker-openldap

# Shared configuration-version marker I/O and offline migrations for persisted
# cn=config state. run.sh owns lifecycle order and provides log and run_as_openldap.

config_migration_root=/etc/ldap/slapd.d
config_migration_journal=$config_migration_root/.upgrade-legacy-ppolicy
config_migration_state_file=$config_migration_journal/state
config_migration_state_prefix=vegardit-openldap:upgrade-legacy-ppolicy:v1:
config_migration_legacy_ppolicy_oid=1.3.6.1.4.1.42.2.27.8.1.1

function read_config_version_marker() {
  local marker_file=$1
  # Real markers are short tokens. Leave room for future labels while bounding
  # service-controlled input before it reaches memory or one-line diagnostics.
  local -r marker_max_bytes=128
  local LC_ALL=C
  local version

  if ! version=$(run_as_openldap \
      head -c "$((marker_max_bytes + 1))" -- "$marker_file"); then
    log ERROR "Cannot read configuration version marker [$marker_file]." >&2
    return 1
  fi
  # Command substitution removes the normal final newline. Reject any remaining
  # newline, non-printing byte, empty value, or oversized input without echoing it.
  if [[ ${#version} -gt $marker_max_bytes || ! $version =~ ^[[:print:]]+$ ]]; then
    log ERROR "Configuration version marker [$marker_file] is not a bounded printable value." >&2
    return 1
  fi

  printf '%s\n' "$version"
}

function publish_config_version_marker() {
  local marker_file=$1
  local version=$2
  local temporary_file

  # The marker's parent belongs to openldap, so it cannot provide root-owned
  # integrity. Keep every filesystem open under the service identity instead of
  # letting a service-selected link cross back into the root entrypoint.
  if ! temporary_file=$(run_as_openldap mktemp -- "${marker_file}.tmp.XXXXXX"); then
    log ERROR "Cannot create a temporary configuration version marker beside [$marker_file]."
    return 1
  fi

  # A sibling temporary file guarantees a same-filesystem atomic rename. -T
  # replaces a destination symlink itself instead of following it.
  if printf '%s\n' "$version" | run_as_openldap tee -- "$temporary_file" >/dev/null &&
      run_as_openldap mv -fT -- "$temporary_file" "$marker_file"; then
    return 0
  fi

  log ERROR "Cannot publish configuration version marker [$marker_file]."
  if ! run_as_openldap rm -f -- "$temporary_file"; then
    log WARN "Cannot remove incomplete configuration version marker [$temporary_file]."
  fi
  return 1
}

function config_migration_run_logged() {
  local status

  if run_as_openldap "$@" 2>&1 | log INFO; then
    status=${PIPESTATUS[0]}
  else
    status=${PIPESTATUS[0]}
  fi
  return "$status"
}

function config_migration_publish_state() {
  local state=$1
  local temporary_file

  case "$state" in
    preparing|publishing|published) ;;
    *)
      log ERROR "Cannot publish unknown OpenLDAP configuration migration state."
      return 1
      ;;
  esac
  if ! temporary_file=$(run_as_openldap mktemp -- "$config_migration_journal/.state.tmp.XXXXXX"); then
    log ERROR "Cannot create the OpenLDAP configuration migration state file."
    return 1
  fi
  # The namespaced value distinguishes this image's journal from operator data
  # that happens to use the same directory and generic state filename.
  if printf '%s%s\n' "$config_migration_state_prefix" "$state" |
      run_as_openldap tee -- "$temporary_file" >/dev/null &&
      run_as_openldap mv -fT -- "$temporary_file" "$config_migration_state_file"; then
    return 0
  fi

  log ERROR "Cannot publish OpenLDAP configuration migration state [$state]."
  run_as_openldap rm -f -- "$temporary_file" || true
  return 1
}

function config_migration_read_state() {
  local persisted_state

  [[ -e $config_migration_state_file || -L $config_migration_state_file ]] || return 1
  if [[ -L $config_migration_state_file || ! -f $config_migration_state_file ]]; then
    log ERROR "OpenLDAP configuration migration state is not a regular file."
    return 2
  fi
  if ! persisted_state=$(run_as_openldap head -c 128 -- "$config_migration_state_file"); then
    log ERROR "Cannot read OpenLDAP configuration migration state."
    return 2
  fi
  case "$persisted_state" in
    "${config_migration_state_prefix}preparing") printf '%s\n' preparing ;;
    "${config_migration_state_prefix}publishing") printf '%s\n' publishing ;;
    "${config_migration_state_prefix}published") printf '%s\n' published ;;
    *)
      log ERROR "Unknown OpenLDAP configuration migration state."
      return 2
      ;;
  esac
}

function config_migration_validate_journal() {
  local expected_state=$1
  local actual_state
  local unexpected_entry
  local allowed_name
  local -a allowed_names=(state '.state.tmp.*')
  local -a find_arguments

  if ! actual_state=$(config_migration_read_state) || [[ $actual_state != "$expected_state" ]]; then
    log ERROR "OpenLDAP configuration migration journal does not have the expected [$expected_state] state."
    return 1
  fi

  case "$expected_state" in
    preparing)
      allowed_names+=(working rebuilt config.ldif validation.ldif)
      ;;
    publishing|published)
      allowed_names+=(
        working rebuilt config.ldif validation.ldif live-validation.ldif
        original-cn=config original-cn=config.ldif
      )
      ;;
    *)
      log ERROR "Cannot validate unknown OpenLDAP configuration migration state."
      return 1
      ;;
  esac

  find_arguments=("$config_migration_journal" -mindepth 1 -maxdepth 1)
  for allowed_name in "${allowed_names[@]}"; do
    find_arguments+=(! -name "$allowed_name")
  done
  find_arguments+=(-print -quit)
  if ! unexpected_entry=$(run_as_openldap find "${find_arguments[@]}"); then
    log ERROR "Cannot inspect the OpenLDAP configuration migration journal."
    return 1
  fi
  if [[ -n $unexpected_entry ]]; then
    # The namespaced state distinguishes this cleanup protocol from an accidental
    # directory-name collision; it is not a security boundary against openldap,
    # which owns the parent. Later operator content must still stop deletion.
    log ERROR "OpenLDAP configuration migration journal contains an unexpected entry; leaving it unchanged."
    return 1
  fi
}

function config_migration_remove_journal() {
  local expected_state=$1

  [[ -e $config_migration_journal || -L $config_migration_journal ]] || return 0
  config_migration_validate_journal "$expected_state" || return
  # Recursive removal is permitted only after both the namespaced state and the
  # bounded top-level namespace establish that this is the image's workspace.
  run_as_openldap rm -rf -- "$config_migration_journal"
}

function config_migration_restore_publication() {
  local component
  local live_path
  local original_path

  config_migration_validate_journal publishing || return
  log WARN "Restoring the configuration after an interrupted legacy ppolicy schema publication..."
  for component in 'cn=config' 'cn=config.ldif'; do
    live_path=$config_migration_root/$component
    original_path=$config_migration_journal/original-$component
    if [[ -e $original_path || -L $original_path ]]; then
      # Only these two exact cn=config paths can have been published. Remove a
      # partial replacement before moving the preserved original back atomically.
      if [[ -e $live_path || -L $live_path ]]; then
        run_as_openldap rm -rf -- "$live_path" || return
      fi
      run_as_openldap mv -T -- "$original_path" "$live_path" || return
    fi
  done

  if [[ ! -f $config_migration_root/cn=config.ldif ||
        ! -d $config_migration_root/cn=config ]]; then
    log ERROR "Cannot restore the configuration after an interrupted legacy ppolicy schema publication; preserved files remain under [$config_migration_journal]."
    return 1
  fi

  config_migration_remove_journal publishing || return
  log INFO "Restored the configuration from before the legacy ppolicy schema publication."
}

function config_migration_recover_if_needed() {
  local existing_entry
  local state
  local state_status

  [[ -e $config_migration_journal || -L $config_migration_journal ]] || return 0
  if [[ -L $config_migration_journal || ! -d $config_migration_journal ]]; then
    log ERROR "OpenLDAP configuration migration path [$config_migration_journal] is not a directory."
    return 1
  fi

  if state=$(config_migration_read_state); then
    case "$state" in
      preparing)
        # Preparation changes only disposable copies, so a recognized interrupted
        # workspace can be discarded without touching live cn=config.
        config_migration_remove_journal preparing || return
        log INFO "Discarded interrupted legacy ppolicy schema preparation."
        ;;
      publishing) config_migration_restore_publication || return ;;
      published)
        # The offline conversion is complete. Keep the original configuration
        # until the surrounding 2.6 migration publishes its final version marker.
        config_migration_validate_journal published || return
        return 0
        ;;
    esac
  else
    state_status=$?
    ((state_status == 1)) || return "$state_status"
    # The process can stop between mkdir and the first state publication. Only an
    # empty directory is unambiguously that interruption; preserve any contents.
    if ! existing_entry=$(run_as_openldap find "$config_migration_journal" \
        -mindepth 1 -maxdepth 1 -print -quit); then
      log ERROR "Cannot inspect the unmarked OpenLDAP configuration migration path."
      return 1
    fi
    if [[ -n $existing_entry ]]; then
      log ERROR "Unmarked OpenLDAP configuration migration path is not empty; leaving it unchanged."
      return 1
    fi
    run_as_openldap rmdir -- "$config_migration_journal" || return
  fi
}

function config_migration_find_legacy_ppolicy_schema() (
  local schema_dir=$config_migration_root/cn=config/cn=schema
  local file
  local grep_status
  local -a matches=()

  [[ -e $schema_dir || -L $schema_dir ]] || return 1
  if [[ -L $schema_dir || ! -d $schema_dir ]]; then
    log ERROR "Persisted OpenLDAP schema path [$schema_dir] is not a regular directory." >&2
    return 2
  fi
  # INIT_SH_FILE can alter glob behavior. The subshell keeps these safeguards
  # local while selecting immediate LDIF children of cn=schema bytewise.
  unset GLOBIGNORE
  set +f
  shopt -u dotglob failglob nocaseglob
  export LC_ALL=C
  shopt -s nullglob

  for file in "$schema_dir"/*.ldif; do
    if [[ -L $file || ! -f $file ]]; then
      log ERROR "Persisted OpenLDAP schema entry [$file] is not a regular file." >&2
      return 2
    fi
    if run_as_openldap grep -Fq -- "$config_migration_legacy_ppolicy_oid" "$file"; then
      matches+=("$file")
    else
      grep_status=$?
      if ((grep_status > 1)); then
        log ERROR "Cannot inspect persisted schema file [$file]." >&2
        return "$grep_status"
      fi
    fi
  done

  case ${#matches[@]} in
    0) return 1 ;;
    1) printf '%s\n' "${matches[0]}" ;;
    *)
      log ERROR "Multiple persisted schemas define the legacy ppolicy OID; automatic migration is ambiguous." >&2
      return 2
      ;;
  esac
)

function config_migration_validate_rebuilt() {
  local config_dir=$1
  local validation_export=$2
  local grep_status

  config_migration_run_logged /usr/sbin/slaptest -u -F "$config_dir" || return
  run_as_openldap rm -f -- "$validation_export" || return
  config_migration_run_logged /usr/sbin/slapcat \
    -F "$config_dir" -n 0 -o ldif-wrap=no -l "$validation_export" || return

  if run_as_openldap grep -Fq -- "$config_migration_legacy_ppolicy_oid" "$validation_export"; then
    log ERROR "Rebuilt cn=config still contains the external legacy ppolicy schema."
    return 1
  else
    grep_status=$?
    if ((grep_status > 1)); then
      log ERROR "Cannot inspect the rebuilt OpenLDAP configuration."
      return "$grep_status"
    fi
  fi
}

function config_migration_prepare_rebuilt() {
  local legacy_schema_file=$1
  local schema_basename=${legacy_schema_file##*/}
  local working_dir=$config_migration_journal/working
  local rebuilt_dir=$config_migration_journal/rebuilt
  local config_export=$config_migration_journal/config.ldif
  local validation_export=$config_migration_journal/validation.ldif

  if [[ ! -f $config_migration_root/cn=config.ldif ||
        ! -d $config_migration_root/cn=config ||
        -L $config_migration_root/cn=config.ldif ||
        -L $config_migration_root/cn=config ]]; then
    log ERROR "Persisted cn=config must contain a regular [cn=config.ldif] file and [cn=config] directory."
    return 1
  fi

  run_as_openldap mkdir -m 0700 -- "$config_migration_journal" || return
  # Publish ownership before writing disposable copies. Recovery may recursively
  # remove only a journal carrying this recognized preparation state.
  config_migration_publish_state preparing || return
  run_as_openldap mkdir -m 0700 -- "$working_dir" "$rebuilt_dir" || return
  run_as_openldap cp -a -- \
    "$config_migration_root/cn=config.ldif" \
    "$config_migration_root/cn=config" \
    "$working_dir/" || return

  # Edit only the disposable copy. slapcat then exposes OpenLDAP's normalized
  # logical ordering, and slapadd regenerates ordered filenames and CRC metadata.
  run_as_openldap rm -f -- "$working_dir/cn=config/cn=schema/$schema_basename" || return
  config_migration_run_logged /usr/sbin/slapcat \
    -F "$working_dir" -n 0 -o ldif-wrap=no -l "$config_export" || return
  config_migration_run_logged /usr/sbin/slapadd \
    -F "$rebuilt_dir" -n 0 -l "$config_export" || return
  config_migration_validate_rebuilt "$rebuilt_dir" "$validation_export"
}

function config_migration_publish_rebuilt() {
  local rebuilt_dir=$config_migration_journal/rebuilt
  local validation_export=$config_migration_journal/live-validation.ldif
  local component

  config_migration_publish_state publishing || return

  for component in 'cn=config' 'cn=config.ldif'; do
    if ! run_as_openldap mv -T -- \
        "$config_migration_root/$component" \
        "$config_migration_journal/original-$component"; then
      config_migration_restore_publication || true
      return 1
    fi
  done
  for component in 'cn=config' 'cn=config.ldif'; do
    if ! run_as_openldap mv -T -- \
        "$rebuilt_dir/$component" \
        "$config_migration_root/$component"; then
      config_migration_restore_publication || true
      return 1
    fi
  done

  if ! config_migration_validate_rebuilt "$config_migration_root" "$validation_export"; then
    log ERROR "Published OpenLDAP configuration failed validation; restoring the pre-migration configuration."
    config_migration_restore_publication || true
    return 1
  fi
  config_migration_publish_state published || return
}

function migrate_legacy_ppolicy_schema() {
  local initialized_file=$1
  local last_version
  local legacy_schema_file
  local find_status
  local state

  config_migration_recover_if_needed || return
  if [[ -d $config_migration_journal ]] &&
      state=$(config_migration_read_state) && [[ $state == published ]]; then
    return 0
  fi

  last_version=$(read_config_version_marker "$initialized_file") || return
  # The published 2.4.x image uses marker 1. Marker 2.5 is also eligible because
  # an interrupted earlier upgrade can retain the same external schema. Do not
  # partially migrate arbitrary version labels that PPM will reject afterward.
  case "$last_version" in
    1|2.5) ;;
    *) return 0 ;;
  esac

  if legacy_schema_file=$(config_migration_find_legacy_ppolicy_schema); then
    :
  else
    find_status=$?
    ((find_status == 1)) && return 0
    return "$find_status"
  fi
  [[ -n $legacy_schema_file ]] || return 0

  log BOX "Migrating legacy ppolicy schema for OpenLDAP 2.6..."
  if ! config_migration_prepare_rebuilt "$legacy_schema_file"; then
    log ERROR "Cannot prepare the legacy ppolicy schema migration; live cn=config was not changed."
    config_migration_remove_journal preparing || true
    return 1
  fi
  if ! config_migration_publish_rebuilt; then
    log ERROR "Cannot publish the legacy ppolicy schema migration."
    return 1
  fi
  log INFO "Removed the external legacy ppolicy schema from cn=config."
}

function finalize_legacy_ppolicy_schema_migration() {
  local initialized_file=$1
  local current_version=$2
  local last_version
  local state

  [[ -d $config_migration_journal ]] || return 0
  state=$(config_migration_read_state) || return
  [[ $state == published ]] || return 0
  last_version=$(read_config_version_marker "$initialized_file") || return
  [[ $last_version == "$current_version" ]] || return 0

  config_migration_remove_journal published || return
  log INFO "Finalized the legacy ppolicy schema migration."
}
