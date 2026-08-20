# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# libvirt/KVM test box for acidnetworks.backupbox_freebsd.
#
# Exists because the first run against real hardware is where the unverified
# parts surface: pf anchor syntax, package names, the rest-server rc.d script
# name, and whether the rsync port ships rrsync. Cheaper to find out here.
#
# Box choice follows base_freebsd: no libvirt FreeBSD-15 box is published, so
# the default is generic/freebsd14. That matters more here than in base, because
# a thin jail shares the host kernel, so jail_base tracks the box automatically.
# major version below, and jail_base asserts they match.
#     FREEBSD_BOX=generic/freebsd15 vagrant up
#
# Tailscale is off. It cannot authenticate without a key and there is no tailnet
# to advertise into. Jail routing does not depend on it: gateway_enable and
# net.inet.ip.forwarding live in jail_host.
#
# RACCT is a loader tunable, so rctl rules do nothing until a reboot:
#     vagrant up && vagrant reload && vagrant provision

FREEBSD_BOX = ENV.fetch("FREEBSD_BOX", "bento/freebsd-14")
BOX_VERSION = ENV.fetch("BOX_VERSION", "202508.03.0")
MGMT_CIDR   = ENV.fetch("FREEBSD_MGMT_CIDR", "192.168.121.0/24")
# generic/freebsd14 is 14.0, which is EOL and deleted from every mirror, so its
# own base.txz cannot be fetched. Pin the jail base to a supported 14.x instead.
# jail_base warns about the mismatch, which is correct: a newer userland on an
# older kernel is the risky direction and is a VM-only compromise, never
# something to do on erebus.
#
# It has to be the NEWEST 14.x, not merely a supported one. The FreeBSD:14:amd64
# repo is built against the newest release in the branch, so packages carry that
# __FreeBSD_version and pkg refuses to install them into an older userland. On
# erebus this never arises: jail_base tracks freebsd-version -u, so a host
# freebsd-update advances the jail base with it.
POOL_DISK   = ENV.fetch("POOL_DISK", "20G")

# Throwaway client keys, generated on first use and gitignored. Committing
# private keys to a public repo is a bad habit even when they are disposable.
%w[alpha beta].each do |c|
  key = "#{__dir__}/tests/files/client_#{c}"
  next if File.exist?("#{key}.pub")
  require "fileutils"
  FileUtils.mkdir_p("#{__dir__}/tests/files")
  system("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "#{c}@backupbox-test", "-f", key) ||
    raise("could not generate test key for #{c}")
end

Vagrant.configure("2") do |config|
  config.vm.box_check_update = false
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.define "backupbox" do |bb|
    bb.vm.box = FREEBSD_BOX
    bb.vm.box_version = BOX_VERSION
    bb.vm.hostname = "backupbox-test"
    bb.vm.guest = :freebsd
    bb.ssh.shell = "/bin/sh"

    bb.vm.provider :libvirt do |libvirt|
      libvirt.driver = "kvm"
      libvirt.uri = "qemu:///system"
      # Jails plus borg plus rest-server. 2G is tight once rctl memoryuse
      # accounting is live.
      libvirt.memory = "4096"
      libvirt.cpus = 2
      # Stands in for erebus's 4TB disk. The app layer never touches the root
      # pool's layout, so size is irrelevant beyond fitting a few test archives.
      libvirt.storage :file, size: POOL_DISK, type: "qcow2"
    end

    # The real box already has an imported `backup` pool, created during install
    # behind GELI. Here the second disk is raw, so make the pool first. No GELI:
    # this validates the app layer, not the unlock chain, which lives in
    # freebsd-outerbase.
    bb.vm.provision "shell", inline: <<~SH
      set -eu
      if ! zpool list backup >/dev/null 2>&1; then
          boot=$(gpart show -p | awk '/freebsd-(boot|zfs|ufs)|efi/ { print $3 }' | sed 's/p[0-9]*$//' | head -1)
          disk=$(sysctl -n kern.disks | tr ' ' '\n' | grep -v "^${boot}$" | head -1)
          [ -n "$disk" ] || { echo "no spare disk found"; exit 1; }
          echo "creating backup pool on /dev/${disk}"
          zpool create -m /backup backup "/dev/${disk}"
      fi
      zpool list backup
    SH

    bb.vm.provision "ansible" do |a|
      a.playbook = "tests/chain.yml"
      a.compatibility_mode = "2.0"
      # chain.yml imports the two sibling collections by FQCN, so they have to be
      # installed first or ansible reads the name as a relative file path. The
      # default galaxy_command passes --roles-path, which ansible-galaxy rejects
      # for a collections requirements file.
      a.galaxy_role_file = "tests/requirements.yml"
      a.galaxy_command = "ansible-galaxy install -r %{role_file}"
      a.groups = {
        "base_hosts"     => ["backupbox"],
        "backup_hosts"   => ["backupbox"],
        "hardened_hosts" => ["backupbox"],
      }
      # The provisioner builds its own inventory, so every contract var the
      # three layers read has to be passed here rather than from group_vars.
      a.extra_vars = {
        "management_cidrs"       => [MGMT_CIDR],
        "firewall_service_cidrs" => [MGMT_CIDR],
        "firewall_allow_tcp_mgmt" => [22],
        "firewall_allow_tcp_svc" => [22, 8000, 2222],
        "firewall_allow_tcp"     => [],
        "target_users" => [
          { "name" => "root", "home" => "/root", "group" => "wheel" },
          { "name" => "vagrant", "home" => "/home/vagrant", "group" => "vagrant" },
        ],
        # Deliberately NOT set to "vagrant". base_users writes
        # sudoers.d/10-<user> for both, so pointing them at the box's own login
        # account rewrites its sudo rules and costs you passwordless become.
        # Leaving them at the acid/ansible defaults keeps vagrant untouched;
        # ssh_hardening's self-heal still adds ansible_user to sshusers.
        "base_users_ssh_dir" => "#{__dir__}/files/ssh",

        "backup_pool" => "backup",
        "backup_root" => "/backup",
        # Production puts jail roots on the SSD's zroot. The generic/freebsd14
        # box has a UFS root and no second pool to spare, so they go on the
        # backup pool here. Structurally identical, just a different parent.
        "jail_dataset" => "backup/jails",
        "jail_dataset_mount" => "/jails",
        "jail_subnet" => "10.100.0.0/16",
        "zrecv_port" => 2222,
        "jails" => [
          { "name" => "borg",   "id" => 1, "port" => 22 },
          { "name" => "restic", "id" => 2, "port" => 8000 },
          { "name" => "rsync",  "id" => 3, "port" => 22 },
        ],

        # One client per ingest path, so a single converge exercises all four.
        # transfer: sftp on the second one covers the chroot branch that the
        # rrsync branch does not.
        "backup_clients" => [
          { "name" => "alpha", "uid" => 5001,
            "services" => ["borg", "restic", "rsync", "zrecv"],
            "transfer" => "rsync", "quota" => "2G", "max_age_hours" => 26,
            "ssh_key" => File.read("#{__dir__}/tests/files/client_alpha.pub").strip },
          { "name" => "beta", "uid" => 5002,
            "services" => ["rsync"],
            "transfer" => "sftp", "quota" => "1G", "max_age_hours" => 72,
            "ssh_key" => File.read("#{__dir__}/tests/files/client_beta.pub").strip },
        ],
        "vault_restic_passwords" => { "alpha" => "vagrant-test-only" },
        "vault_healthchecks" => {},

        "backup_network_enabled" => false,
        # The FreeBSD:14:amd64 repo is built against 14.4 while this box is 14.3,
        # so pkg refuses the catalogue without this. erebus runs the newest 15.x
        # and does not need it.
        "jail_pkg_environment" => { "IGNORE_OSVERSION" => "yes" },

        # hardening: keep the run short and leave the box reachable.
        "chkrootkit_enabled" => false,
        "lynis_enabled" => false,
        "ssh_2fa_totp_enabled" => false,
        "ssh_2fa_fido2_enabled" => false,
        "harden_safe_rollback" => false,
        # Vagrant's provisioners talk through Ruby net-ssh, which supports none
        # of ssh_hardening's pinned kex algorithms, so after the first harden run
        # every later `vagrant provision` dies with "could not settle on kex
        # algorithm". Ansible and `vagrant ssh` use the OpenSSH binary and are
        # fine. Add one kex net-ssh does support rather than turning
        # ssh_pin_crypto off, so the rest of the pinning is still exercised.
        # Harness-only: erebus is administered over OpenSSH and needs none of it.
        "ssh_kex" => "curve25519-sha256,curve25519-sha256@libssh.org," \
                     "diffie-hellman-group16-sha512,diffie-hellman-group18-sha512," \
                     "diffie-hellman-group14-sha256",
      }
    end
  end
end
