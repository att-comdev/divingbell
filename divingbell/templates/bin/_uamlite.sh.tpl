#!/bin/bash

{{/*
# Copyright 2017 AT&T Intellectual Property.  All other rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
*/}}

set -e

cat <<'EOF' > {{ .Values.conf.chroot_mnt_path | quote }}/tmp/uamlite_host.sh
{{ include "divingbell.shcommon" . }}

keyword='divingbell'
builtin_acct='ubuntu'

add_user(){
  die_if_null "${user_name}" ", 'user_name' env var not initialized"
  : ${user_sudo:=false}

  # Create user if user does not already exist
  getent passwd ${user_name} && \
    log.INFO "User '${user_name}' already exists" || \
  (useradd --create-home --shell /bin/bash --comment ${keyword} ${user_name} && \
    log.INFO "User '${user_name}' successfully created")

  # Unexpire the user (if user had been previously expired)
  if [ "$(chage -l ${user_name} | grep 'Account expires' | cut -d':' -f2 |
          tr -d '[:space:]')" != "never" ]; then
    usermod --expiredate "" ${user_name}
    log.INFO "User '${user_name}' has been unexpired"
  fi

  # Add sudoers entry if requested for user
  if [ "${user_sudo}" = 'true' ]; then
    # Add sudoers entry if it does not already exist
    user_sudo_file=/etc/sudoers.d/${keyword}-${user_name}-sudo
    if [ -f "${user_sudo_file}" ] ; then
      log.INFO "User '${user_name}' already added to sudoers: ${user_sudo_file}"
    else
      echo "${user_name} ALL=(ALL) NOPASSWD:ALL" > "${user_sudo_file}"
      log.INFO "User '${user_name}' added to sudoers: ${user_sudo_file}"
    fi
    curr_sudoers="${curr_sudoers}${user_sudo_file}"$'\n'
  else
    log.INFO "User '${user_name}' was not requested sudo access"
  fi

  curr_userlist="${curr_userlist}${user_name}"$'\n'
}

add_sshkeys(){
  die_if_null "${user_name}" ", 'user_name' env var not initialized"
  user_sshkeys="$@"

  sshkey_dir="/home/${user_name}/.ssh"
  sshkey_file="${sshkey_dir}/authorized_keys"
  if [ -z "${user_sshkeys}" ]; then
    log.INFO "User '${user_name}' has no SSH keys defined"
    if [ -f "${sshkey_file}" ]; then
      rm "${sshkey_file}"
      log.INFO "User '${user_name}' has had its authorized_keys file wiped"
    fi
  else
    sshkey_file_contents='# NOTE: This file is managed by divingbell'$'\n'
    for sshkey in "$@"; do
      sshkey_file_contents="${sshkey_file_contents}${sshkey}"$'\n'
    done
    write_file=false
    if [ -f "${sshkey_file}" ]; then
      if [ "$(cat "${sshkey_file}")" = \
           "$(echo "${sshkey_file_contents}" | head -n-1)" ]; then
        log.INFO "User '${user_name}' has no new SSH keys"
      else
        write_file=true
      fi
    else
      write_file=true
    fi
    if [ "${write_file}" = "true" ]; then
      mkdir -p "${sshkey_dir}"
      chmod 700 "${sshkey_dir}"
      echo -e "${sshkey_file_contents}" > "${sshkey_file}"
      chown -R ${user_name}:${user_name} "${sshkey_dir}" || \
        (rm "${sshkey_file}" && die "Error setting ownership on ${sshkey_dir}")
      log.INFO "User '${user_name}' has had SSH keys deployed: ${user_sshkeys}"
    fi
    custom_sshkeys_present=true
  fi

}

{{- if hasKey .Values.conf "uamlite" }}
{{- if hasKey .Values.conf.uamlite "users" }}
{{- range $item := .Values.conf.uamlite.users }}
  {{- range $key, $value := . }}
    {{ $key }}={{ $value | quote }} \
  {{- end }}
  add_user

  {{- range $key, $value := . }}
    {{ $key }}={{ $value | quote }} \
  {{- end }}
  add_sshkeys {{ range $ssh_key := .user_sshkeys }}{{ $ssh_key | quote }} {{end}}
{{- end }}
{{- end }}
{{- end }}

# TODO: This should be done before applying new settings rather than after
# Expire any previously defined users that are no longer defined
users="$(getent passwd | grep ${keyword} | cut -d':' -f1)"
echo "$users" | sort > /tmp/prev_users
echo "$curr_userlist" | sort > /tmp/curr_users
revert_list="$(comm -23 /tmp/prev_users /tmp/curr_users)"
IFS=$'\n'
for user in ${revert_list}; do
  # We expire rather than delete the user to maintain local UID FS consistency
  usermod --expiredate 1 ${user}
  log.INFO "User '${user}' has been disabled (expired)"
done

# Delete any previous user sudo access that is no longer defined
sudoers="$(find /etc/sudoers.d | grep ${keyword})"
echo "$sudoers" | sort > /tmp/prev_sudoers
echo "$curr_sudoers" | sort > /tmp/curr_sudoers
revert_list="$(comm -23 /tmp/prev_sudoers /tmp/curr_sudoers)"
IFS=$'\n'
for sudo_file in ${revert_list}; do
  rm "${sudo_file}"
  log.INFO "Sudoers file '${sudo_file}' has been deleted"
done

if [ -n "${builtin_acct}" ] && [ -n "$(getent passwd ${builtin_acct})" ]; then
  # Disable built-in account as long as there was at least one account defined
  # in this chart with a ssh key present
  if [ "${custom_sshkeys_present}" = "true" ]; then
    if [ "$(chage -l ${builtin_acct} | grep 'Account expires' | cut -d':' -f2 |
          tr -d '[:space:]')" = "never" ]; then
      usermod --expiredate 1 ${builtin_acct}
    fi
  # Re-enable built-in account as a fallback in the event that are no other
  # accounts defined in this chart with a ssh key present
  else
    if [ "$(chage -l ${builtin_acct} | grep 'Account expires' | cut -d':' -f2 |
          tr -d '[:space:]')" != "never" ]; then
      usermod --expiredate "" ${builtin_acct}
    fi
  fi
fi

if [ -n "${curr_userlist}" ]; then
  log.INFO 'All uamlite data successfully validated on this node.'
else
  log.WARN 'No uamlite overrides defined for this node.'
fi

exit 0
EOF

chmod 755 {{ .Values.conf.chroot_mnt_path | quote }}/tmp/uamlite_host.sh
chroot {{ .Values.conf.chroot_mnt_path | quote }} /tmp/uamlite_host.sh

sleep 1
echo 'INFO Putting the daemon to sleep.'

while [ 1 ]; do
  sleep 300
done

exit 0

