#!/bin/bash

{{/*
Copyright 2017 The Openstack-Helm Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/}}

set -e

cat <<'EOF' > {{ .chroot_mnt_path | quote }}/tmp/sysctl_host.sh
#!/bin/bash

set -o errtrace
set -o pipefail

declare -Ax __log_types=(
  [ERROR]='fd=2, color=\e[01;31m'
  [TRACE]='fd=2, color=\e[01;31m'
  [WARN]='fd=1, color=\e[01;93m'
  [INFO]='fd=1, color=\e[01;37m'
  [DEBUG]='fd=1, color=\e[01;90m'
)
for __log_type in "${!__log_types[@]}"; do
  alias log.${__log_type}="echo ${__log_type}"
done
shopt -s expand_aliases

__text_formatter(){
  local log_prefix='None'
  local default_log_type='INFO'
  local default_xtrace_type='DEBUG'
  local log_type
  local color_prefix
  local fd
  for log_type in "${!__log_types[@]}"; do
    if [[ ${1} == ${log_type}* ]]; then
      log_prefix=''
      color_prefix="$(echo ${__log_types["${log_type}"]} |
                      cut -d',' -f2 | cut -d'=' -f2)"
      fd="$(echo ${__log_types["${log_type}"]} |
            cut -d',' -f1 | cut -d'=' -f2)"
      break
    fi
  done
  if [ "${log_prefix}" = "None" ]; then
    # xtrace output usually begins with "+" or "'", mark as debug
    if [[ ${1} = '+'* ]] || [[ ${1} = \'* ]]; then
      log_prefix="${default_xtrace_type} "
      log_type="${default_xtrace_type}"
    else
      log_prefix="${default_log_type} "
      log_type="${default_log_type}"
    fi
    color_prefix="$(echo ${__log_types["${log_type}"]} |
                    cut -d',' -f2 | cut -d'=' -f2)"
    fd="$(echo ${__log_types["${log_type}"]} |
          cut -d',' -f1 | cut -d'=' -f2)"
  fi
  local color_suffix=''
  if [ -n "${color_prefix}" ]; then
    color_suffix='\e[0m'
  fi
  echo -e "${color_prefix}${log_prefix}${1}${color_suffix}" >&${fd}
}
# Due to this unresolved issue: http://bit.ly/2xPmOY9 we choose preservation of
# message ordering at the expense of applying appropriate tags to stderr. As a
# result, stderr from subprocesses will still display as INFO level messages.
# However we can still log ERROR messages using the aliased log handlers.
exec >& >(while read line; do __text_formatter "${line}"; done)

die(){
  set +x
  # write to stderr any passed error message
  if [[ $@ = *[!\ ]* ]]; then
    log.ERROR "$@"
  fi
  log.TRACE "Backtrace:"
  for ((i=0;i<${#FUNCNAME[@]}-1;i++)); do
    log.TRACE $(caller $i)
  done
  # allow enough time to finish stacktrace print before exiting
  sleep 1
  exit 1
}
export -f die
trap 'die' ERR
set -x

###############################################################################

# TODO: Make prefix configurable to control param loading order
fname_prefix='60-divingbell-'
defaults_path='/var/divingbell/sysctl'
persist_path='/etc/sysctl.d'
reload_system_configs=false

if [ ! -d "${defaults_path}" ]; then
  mkdir -p "${defaults_path}"
fi

die_if_null(){
  local var="${1}"
  shift
  [ -n "${var}" ] || die "Null variable exception $@"
}

add_sysctl_param(){
  local user_key="${1}"
  die_if_null "${user_key}" ", 'user_key' not supplied to function"
  local user_val="${2}"
  die_if_null "${user_val}" ", 'user_val' not supplied to function"

  # Try reading the current sysctl tunable param / value
  # If sysctl cannot find the specified tunable, script will exit here
  local system_key_val_pair
  system_key_val_pair="$(sysctl $user_key)"

  # For further operation, use the tunable name returned by sysctl above,
  # rather than the one specified by the user.
  # sysctl gives a consistently formatted tunable (e.g., net.ipv4.ip_forward)
  # regardless of input format (e.g., net/ipv4/ip_forward).
  local system_key
  system_key="$(echo ${system_key_val_pair} |
                cut -d'=' -f1 | tr -d '[:space:]')"
  [ -n "${system_key}" ] || die 'Null variable exception'

  # Store current kernel sysctl default in the event we need to restore later
  # But only if it is the first time we are changing the tunable,
  # to capture the orignal value.
  local system_val
  system_val="$(echo ${system_key_val_pair} |
                cut -d'=' -f2 | tr -d '[:space:]')"
  [ -n "${system_val}" ] || die 'Null variable exception'
  local orig_val="${defaults_path}/${fname_prefix}${system_key}.conf"
  if [ ! -f "${orig_val}" ]; then
    echo "${system_key_val_pair}" > "${orig_val}"
  fi

  # Apply new setting. If an invalid value were provided, sysctl would choke
  # here, before making the change persistent.
  if [ "${user_val}" != "${system_val}" ]; then
    sysctl -w "${system_key}=${user_val}"
  fi

  # Persist the new setting
  file_content="${system_key}=${user_val}"
  file_path="${persist_path}/${fname_prefix}${system_key}.conf"
  if [ -f "${file_path}" ] &&
     [ "$(cat ${file_path})" != "${file_content}" ] ||
     [ ! -f "${file_path}" ]
  then
    echo "${file_content}" > "${file_path}"
    reload_system_configs=true
    log.INFO "Sysctl setting applied: ${system_key}=${user_val}"
  else
    log.INFO "No changes made to sysctl param: ${system_key}=${user_val}"
  fi

  curr_settings="${curr_settings}${fname_prefix}${system_key}.conf"$'\n'
}

{{- range $key, $value := .sysctl }}
add_sysctl_param {{ $key | quote }} {{ $value | quote }}
{{- end }}

# Revert any previously applied sysctl settings which are now absent
prev_files="$(find "${defaults_path}" -type f)"
if [ -n "${prev_files}" ]; then
  basename -a ${prev_files} | sort > /tmp/prev_settings
  echo "${curr_settings}" | sort > /tmp/curr_settings
  revert_list="$(comm -23 /tmp/prev_settings /tmp/curr_settings)"
  IFS=$'\n'
  for orig_sysctl_setting in ${revert_list}; do
    rm "${persist_path}/${orig_sysctl_setting}"
    sysctl -p "${defaults_path}/${orig_sysctl_setting}"
    rm "${defaults_path}/${orig_sysctl_setting}"
    reload_system_configs=true
    log.INFO "Reverted sysctl setting:" \
             "$(cat "${defaults_path}/${orig_sysctl_setting}")"
  done
fi

# Final validation of sysctl settings written to /etc/sysctl.d
# Also allows for nice play with other automation (or manual) systems that
# may have separate overrides for reverted tunables.
if [ "${reload_system_configs}" = "true" ]; then
  sysctl --system
fi

if [ -n "${curr_settings}" ]; then
  log.INFO 'All sysctl configuration successfully validated on this node.'
else
  log.WARN 'No syctl overrides defined for this node.'
fi

exit 0
EOF

chmod 755 {{ .chroot_mnt_path | quote }}/tmp/sysctl_host.sh
chroot {{ .chroot_mnt_path | quote }} /tmp/sysctl_host.sh

sleep 1
echo 'INFO Putting the daemon to sleep.'

while [ 1 ]; do
  sleep 300
done

exit 0
