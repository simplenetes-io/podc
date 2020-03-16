#!/usr/bin/env sh

#
# Check required programs
if ! command -v curl >/dev/null; then
    printf "FAIL: curl program is required\n" 1>&2
    exit 1
fi

if ! command -v VBoxManage >/dev/null; then
    printf "FAIL: VBoxManage program is required\n" 1>&2
    exit 1
fi

#
# Setup URL and file name
_image_base_url="https://github.com/boot2podman/boot2podman/releases/download/v0.25"
_image_name="boot2podman.iso"
_image_full_url="${_image_base_url}/${_image_name}"

#
# Download boot2podman disk image
# Check file is available and download it if needed
if [ ! -f "./${_image_name}" ]; then
    printf "Image file %s was not found. Downloading from %s...\n" "${_image_name}" "${_image_full_url}" 1>&2
    curl -LO "${_image_full_url}"
    _exit_code="$?"
    if [ "$_exit_code" -ne 0 ]; then
        printf "Failed to curl %s from %s. Returned %s\n" "${_image_name}" "${_image_base_url}" "$_exit_code" 1>&2
        exit "$_exit_code"
    fi
fi

#
# FIXME: missing file integrity check around here
#

if [ ! -f "${_image_name}" ]; then
    printf "Unexpected error: missing %s image file.\n" "${_image_name}" 1>&2
    exit 1
fi

#
# Create new VM
_vm_name="podcompilerVM"
if ! VBoxManage showvminfo ${_vm_name} >/dev/null 2>&1; then
    VBoxManage createvm --name ${_vm_name} --ostype Debian_64 --register
    VBoxManage modifyvm ${_vm_name} --memory 1024
    VBoxManage modifyvm ${_vm_name} --natpf1 rule1,tcp,,2222,,22
    VBoxManage storagectl ${_vm_name} --name "IDE Controller" --add ide
    VBoxManage storageattach ${_vm_name} --storagectl "IDE Controller" --port 0 --device 0 --type dvddrive --medium ${_image_name}
fi

#
# Run VM
VBoxManage startvm ${_vm_name}
if [ "$?" -ne 0 ]; then
    exit 1
fi

printf "\n===== INSTRUCTIONS =====\n\n Before proceeding, remove [127.0.0.1]:2222 entry from ~/.ssh/known_hosts if that exists

 > Inside %s (Guest):
 > Login is expected to happen automatically.
 > User: tc
 >
 > Then proceed with the following commands:
 $ passwd
 $ sudo -s
 # echo \"PasswordAuthentication yes\" >> /usr/local/etc/ssh/sshd_config
 # echo \"MaxAuthTries 100\" >> /usr/local/etc/ssh/sshd_config
 # /usr/local/etc/init.d/openssh restart
 # exit

 From the Host computer, ssh will now be available:
 $ ssh tc@127.0.0.1 -p 2222

 Running Space commands inside the Guest OS can be done with the assistance of the ssh Space Module:
 $ source env.sh; space /_export/ -m ssh /wrap/ -e SSHUSER=tc -e SSHHOST=127.0.0.1 -e SSHPORT=2222 -e SPACE_ENV=\"\${SPACE_ENV}\" -- run
 \n" "${_vm_name}"
