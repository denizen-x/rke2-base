#!/usr/bin/env bash
exec 1> >(logger -s -t $(basename $0)) 2>&1
# · ---
export DEBIAN_FRONTEND=noninteractive
# · ---
NCPU=$(nproc)
NPID=$((32768 * ($NCPU - 1) - 1))
NTROPY="$(cat /proc/sys/kernel/random/entropy_avail)"
OS="$(uname | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')"
# · ---
bashrc_prefs ()
{
    local u="${1:-}"; local h; local f;

    [[ "${u}" == "root" ]] && h=/root || h=/home/"${u}"; f=$h/.bashrc;
    [[ -f "$f" ]] || return;

    [[ -f $h/.selected_editor ]] || cp -aux /etc/skel/.selected_editor $h/.selected_editor;

    sed -i 's/^#force_color_prompt/force_color_prompt/g' $f;
    
    echo -e "\n[[ -f /etc/bash_completion ]] && ! shopt -oq posix && . /etc/bash_completion" >> $f;
    echo -e "\n[[ -f /srv/data/local/etc/kuberc ]] && . /srv/data/local/etc/kuberc\n" >> $f;
    echo 'export PS1="\[\e[31m\][\[\e[m\]\[\e[38;5;172m\]\u\[\e[m\]@\[\e[38;5;153m\]\h\[\e[m\] \[\e[38;5;214m\]\W\[\e[m\]\[\e[31m\]]\[\e[m\]\\$ "' >> $f;
    
    echo -e "\nalias top-cpu='top -b -o +%CPU | head -n 22'" >> $f;
    echo -e "\nalias top-mem='top -b -o +%MEM | head -n 22'" >> $f;
    
    mkdir -pm 0750 $h/.kube && chown $u:$u $h/.kube;
    touch $h/.kube/config && chmod 0600 $h/.kube/config;
    chown $u:$u $h/.kube/config $h/.selected_editor;
}

iface_names ()
{
    local -a d=()
    
    for n in $(find /sys/class/net -type l -not -lname '*virtual*' -printf '%f ' | tr " " "\n" | sort); do
        d+=( "$n" );
    done
    
    echo "${d[*]}"
}

iface_addr ()
{
    [[ -z "${1:-}" ]] && return || echo "$(ip -4 -f inet a show ${1} | awk '/inet/{ print $2 }' | awk -F "/" '{ print $1 }')"
}
# · ---
[[ -f /root/environment.local ]] && source /root/environment.local && rm -f /root/environment.local
THIS_ROLE="${THIS_ROLE:-worker}"
THIS_USER="${THIS_USER:-}"
THIS_LANG="${THIS_LANG:-es_ES}"
THIS_DOMAIN="${THIS_DOMAIN:-}"
THIS_DOMAIN_LOCAL="${THIS_DOMAIN_LOCAL:-}"
THIS_SSH="${THIS_SSH:-22}"
THIS_SSH_KEEP="${THIS_SSH_KEEP:-0}"
THIS_CIDR="$THIS_CIDR" || THIS_CIDR="10.0.0.0/16";
THIS_CIDR_POD="$THIS_CIDR_POD" || THIS_CIDR_POD="10.42.0.0/16";
THIS_CIDR_SVC="$THIS_CIDR_SVC" || THIS_CIDR_SVC="10.43.0.0/16";
THIS_IPV6="${THIS_IPV6:-0}";
THIS_IFACES+=( $(iface_names) )
THIS_IF0="${THIS_IFACES[0]}"
THIS_IF1="${THIS_IFACES[1]}"
THIS_IF2="${THIS_IFACES[2]}"
THIS_IF0_IP="$(iface_addr ${THIS_IF0:-})"
THIS_IF1_IP="$(iface_addr ${THIS_IF1:-})"
THIS_IF2_IP="$(iface_addr ${THIS_IF2:-})"

# · ---
echo -e "| CLOUD-FINISH ... :: start :: ..."
# · ---
# Locales
localectl set-locale LANGUAGE="es_ES:en:en_US" LC_MESSAGES=C LC_COLLATE=C;

# Custom dirs
cd ~;
mkdir -pm0751 /etc/rancher /srv/{backup,data} /var/lib/rancher /mnt/{storage,tmp};
mkdir -pm0751 /srv/data/{local/{bin,etc},rke2} /etc/rancher/rke2;
chmod 0755 /srv/data /srv/data/local/etc;
chmod 0750 /etc/rancher/rke2 /srv/data/rke2;

# Default config files
if [[ -d /root/rke2-base ]]; then
    install -Dm0751 /root/rke2-base/node/bin/vm-drop-caches /srv/data/local/bin/vm-drop-caches \
      && cp -aux /srv/data/local/bin/vm-drop-caches /usr/local/bin/;
    install -Dm0600 /root/rke2-base/node/etc/ssh/sshd_config /etc/ssh/sshd_config;
    install -Dm0644 /root/rke2-base/node/etc/sysctl.d/999-local.conf /etc/sysctl.d/999-local.conf;
    install -Dm0644 /root/rke2-base/node/etc/fail2ban/jail.d/sshd.conf /etc/fail2ban/jail.d/sshd.conf;
    install -Dm0644 /root/rke2-base/node/etc/kuberc /srv/data/local/etc/kuberc;
fi

touch /srv/data/rke2/config.yaml && chmod 0640 /srv/data/rke2/config.yaml;

# Entropy
[[ ${NTROPY:-0} -lt 1024 ]] && systemctl enable haveged.service --now;

# Trim support
echo "0 2 * * 5      root    /usr/sbin/fstrim --all" > /etc/cron.d/fstrim && chmod 0751 /etc/cron.d/fstrim;

# Drom vm caches
echo "0 3 * * *      root    /usr/local/bin/vm-drop-caches" > /etc/cron.d/vm-drop-caches && chmod 0751 /etc/cron.d/vm-drop-caches;

# /tmp tmpfs
sed 's/^Options=/Options=noexec,/g' /usr/share/systemd/tmp.mount > /etc/systemd/system/tmp.mount;
sed -i '/^#DPkg.*/s/^#//' /etc/apt/apt.conf.d/94cloud-init-config;
rm -Rf /tmp/* /tmp/.* && systemctl enable tmp.mount --now;

# Grub conf: classic net device names
sed -i -e 's/^GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0"/' /etc/default/grub;
update-grub;

# Disk tune
echo -e "block/sd*/queue/rotational=0\nblock/dm*/queue/rotational=0" > /etc/sysfs.d/rotational-false.conf;
for d in $(lsblk -dnoNAME | grep sd); do
    echo -e "\nblock/${d}/queue/iosched/front_merges = 0" > /etc/sysfs.d/${d}.conf;
    echo "block/${d}/queue/iosched/read_expire = 150" >> /etc/sysfs.d/${d}.conf;
    echo "block/${d}/queue/iosched/write_expire = 1500" >> /etc/sysfs.d/${d}.conf;
done

# SSH config & hardening
rm -f /etc/ssh/ssh_host_*;

ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N "";
ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "";

mv /etc/ssh/moduli /etc/ssh/moduli.dist;
awk '$5 >= 3071' /etc/ssh/moduli.dist > /etc/ssh/moduli;

sed -ri \
    -e "s/^ListenAddress 0.0.0.0/ListenAddress ${THIS_IF0_IP}/g" \
    -e "$([[ ! -z "$THIS_IF1_IP" ]] && echo "/^ListenAddress ${THIS_IF0_IP}$/a ListenAddress ${THIS_IF1_IP}")" \
    -e "$([[ ! -z "$THIS_IF2_IP" ]] && echo "/^ListenAddress ${THIS_IF1_IP}$/a ListenAddress ${THIS_IF2_IP}")" \
    /etc/ssh/sshd_config;

if [[ ! "$THIS_SSH" == "22" ]]; then
    sed -ri -e "s/^Port 22/Port ${THIS_SSH}/" /etc/ssh/ssh_config /etc/ssh/sshd_config;
    sed -i "s/^port = 22$/&,${THIS_SSH}/" /etc/fail2ban/jail.d/sshd.conf;
    [[ "$THIS_SSH_KEEP" = "1" ]] && sed -i "/^Port ${THIS_SSH}/a Port 22" /etc/ssh/sshd_config;
fi

# Domain
[[ -z "${THIS_DOMAIN}" ]] || sed -i "s/^#kernel.domainname/kernel.domainname = $THIS_DOMAIN/g" /etc/sysctl.d/999-local.conf;

if [[ ! -z "${THIS_DOMAIN_LOCAL}" ]]; then
    sed -i "s/^127.0.1.1 $HOSTNAME $HOSTNAME$/127.0.1.1 $HOSTNAME.$THIS_DOMAIN_LOCAL $HOSTNAME/" /etc/hosts;
fi

# SysCtls
sed -ri \
    -e "s/^#(kernel.domainname\s+=).*$/\1 $THIS_DOMAIN/" \
    -e "s/(^kernel.pid_max\s+=).*$/\1 $NPID/" \
    -e "$([[ ! "$THIS_ROLE" == "master" ]] && echo "s/(^fs.file-max\s+=).*$/\1 524287/")" \
    /etc/sysctl.d/999-local.conf

# IPv6 support
[[ "$THIS_IPV6" = "1" ]] && sed -i 's/^net.ipv6/# net.ipv6/g' /etc/sysctl.d/999-local.conf;

# DNS resolv
rm -f /etc/resolv.conf;

cat << 'EOF' > /etc/systemd/resolved.conf
[Resolve]
DNS=185.12.64.1 1.1.1.1 8.8.8.8 2606:4700:4700::1111
DNSStubListener=No
ReadEtcHosts=yes
EOF

cat << 'EOF' > /etc/resolv.conf
nameserver 185.12.64.1
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2606:4700:4700::1111
EOF

# User prefs
bashrc_prefs root;

if [[ ! -z "$THIS_USER" ]]; then
    echo "$THIS_USER:$(cat /dev/urandom | tr -dc 'a-zA-Z0-9#$%&' | fold -w 16 | head -n 1)" | chpasswd;
    bashrc_prefs "$THIS_USER";
fi

# Node role
if [[ "$THIS_ROLE" = "rancher" ]]; then
    # ToDo ...
    THIS_ROLE=master
fi

sudo mount -o remount,exec /tmp;

# RKE2 & kube tools
if [[ ! "$THIS_ROLE" == "master" ]]; then
    # echo iscsi_tcp >> /etc/modules;
    mkdir -pm0755 /mnt/huge;

    curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh -
else
    groupadd -rg 52034 etcd;
    useradd -Mrc 'etcd service account' -s /sbin/nologin -u 52034 -g 52034 etcd;

    # helm
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3;
    chmod 0700 get_helm.sh && ./get_helm.sh && sleep 1 && rm -f get_helm.sh;

    # rke2 & kubectl
    mkdir -pm0750 /var/lib/rancher/rke2/server/manifests;
    touch /srv/data/rke2/rke2-{cilium,coredns,ingress-nginx}-config.yaml;
    chmod 0640 /srv/data/rke2/*.yaml;

    curl -sfL https://get.rke2.io | sh -

    # krew
    (
        set -x; cd "$(mktemp -d)" &&
        KREW="krew-${OS}_${ARCH}" &&
        curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
        tar zxvf "${KREW}.tar.gz" &&
        ./"${KREW}" install krew
    )

fi

sudo mount -o remount,noexec /tmp;

ln -sf /var/lib/rancher/rke2/agent/etc/crictl.yaml /etc/crictl.yaml;

# Reload configs
sysctl --system;

# System Services
systemctl enable sysfsutils;
systemctl enable fail2ban --now;
systemctl enable fstrim.timer --now;
systemctl restart ssh;

# · ---
DEBIAN_FRONTEND=noninteractive apt -y full-upgrade && apt -y autoclean && apt -y autoremove && sync;
fstrim --all;
# · ---
echo -e "| CLOUD-FINISH ... :: end :: ..."
# · ---

return 0
