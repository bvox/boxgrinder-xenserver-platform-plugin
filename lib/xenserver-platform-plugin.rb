#
# Copyright 2010 Red Hat, Inc.
# Copyright 2012 BVox S.L
#
# Original EC2 platform plugin from Boxgrinder tweaked to generate VHD images
# XenServer compatible. Needs VirtualBox installed (VBoxManage in particular)
#
# This is free software; you can redistribute it and/or modify it
# under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation; either version 3 of
# the License, or (at your option) any later version.
#
# This software is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this software; if not, write to the Free
# Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA
# 02110-1301 USA, or see the FSF site: http://www.fsf.org.

require 'boxgrinder-build/plugins/base-plugin'
require 'boxgrinder-build/helpers/linux-helper'
require 'tempfile'
require 'fileutils'

module BoxGrinder
  class XenServerPlugin < BasePlugin
    plugin :type => :platform, :name => :xenserver, :full_name => "XenServer Platform Plugin", :require_root => true

    def after_init
      if %w{fedora rhel centos}.include? @appliance_config.os.name
        register_deliverable(:disk => "#{@appliance_config.name}.raw")
      end
      register_deliverable(:vhd => "#{@appliance_config.name}.vhd")

      register_supported_os('fedora', ['13', '14', '15', '16'])
      register_supported_os('centos', ['5', '6'])
      register_supported_os('sl', ['5', '6'])
      register_supported_os('rhel', ['5', '6'])
      register_supported_os('ubuntu', ['lucid', 'oneiric', 'precise', 'maveric'])
      if `which VBoxManage`.empty?
        @log.error "VBoxManage binary not found in your path, aborting."
        exit 1
      end
    end

    def execute
      if %w{fedora rhel centos}.include? @appliance_config.os.name
        execute_rpmdistro
      else
        execute_ubuntu
      end
    end

    def execute_ubuntu
      convert_to_vhd
    end

    def convert_to_vhd
      @log.info "Converting to VMDK Sparse using qemu-img..."
      if @appliance_config.os.name == 'ubuntu'
        @exec_helper.execute "qemu-img convert -O vmdk '#{@previous_deliverables.disk}' '#{@deliverables.vhd}.vmdk'"
        @log.info "Converting to VHD using VBoxManage..."
        @exec_helper.execute "VBoxManage clonehd --format VHD '#{@deliverables.vhd}.vmdk' '#{@deliverables.vhd}'"
        FileUtils.rm_f "#{@deliverables.vhd}.vmdk"
      else
        @exec_helper.execute "qemu-img convert -O vmdk '#{@deliverables.disk}' '#{@deliverables.disk}.vmdk'"
        @log.info "Converting to VHD using VBoxManage..."
        @exec_helper.execute "VBoxManage clonehd --format VHD '#{@deliverables.disk}.vmdk' '#{@deliverables.vhd}'"
        FileUtils.rm_f "#{@deliverables.disk}.vmdk"
      end
    end

    def execute_rpmdistro
      @linux_helper = LinuxHelper.new(:log => @log)

      @log.info "Converting #{@appliance_config.name} appliance image to XenServer format..."

      @image_helper.create_disk(@deliverables.disk, 10) # 10 GB destination disk

      @image_helper.customize([@previous_deliverables.disk, @deliverables.disk], :automount => false) do |guestfs, guestfs_helper|
        @image_helper.sync_filesystem(guestfs, guestfs_helper)
        
        @log.debug "Uploading '/etc/resolv.conf'..."
        guestfs.upload("/etc/resolv.conf", "/etc/resolv.conf")
        @log.debug "'/etc/resolv.conf' uploaded."

        if (@appliance_config.os.name == 'rhel' or @appliance_config.os.name == 'centos') and @appliance_config.os.version == '5'
          # Remove normal kernel
          guestfs.sh("yum -y remove kernel")
          # because we need to install kernel-xen package
          guestfs_helper.sh("yum -y install kernel-xen", :arch => @appliance_config.hardware.arch)
          # and add require modules
          @linux_helper.recreate_kernel_image(guestfs, ['xenblk', 'xennet'])
        end

        create_devices(guestfs)

        upload_fstab(guestfs)
        enable_networking(guestfs)
        upload_rc_local(guestfs)
        #change_configuration(guestfs_helper)
        install_menu_lst(guestfs)

        enable_nosegneg_flag(guestfs) if @appliance_config.os.name == 'fedora'

        execute_post(guestfs_helper)
      end

      convert_to_vhd

      @log.info "Image converted to XenServer format."
    end

    def execute_post(guestfs_helper)
      unless @appliance_config.post['xenserver'].nil?
        @appliance_config.post['xenserver'].each do |cmd|
          @log.debug "Executing xenserver post command #{cmd}"
          guestfs_helper.sh(cmd, :arch => @appliance_config.hardware.arch)
        end
        @log.debug "Post xenserver commands from appliance definition file executed."
      else
        @log.debug "No xenserver commands specified, skipping."
      end
    end

    def create_devices(guestfs)
      return if guestfs.exists('/sbin/MAKEDEV') == 0

      @log.debug "Creating required devices..."
      guestfs.sh("/sbin/MAKEDEV -d /dev -x console")
      guestfs.sh("/sbin/MAKEDEV -d /dev -x null")
      guestfs.sh("/sbin/MAKEDEV -d /dev -x zero")
      @log.debug "Devices created."
    end

    def disk_device_prefix
      disk = 'xv'
      disk = 's' if (@appliance_config.os.name == 'rhel' or @appliance_config.os.name == 'centos') and @appliance_config.os.version == '5'

      disk
    end

    def upload_fstab(guestfs)
      @log.debug "Uploading '/etc/fstab' file..."

      fstab_file = @appliance_config.is64bit? ? "#{File.dirname(__FILE__)}/src/fstab_64bit" : "#{File.dirname(__FILE__)}/src/fstab_32bit"

      fstab_data = File.open(fstab_file).read
      fstab_data.gsub!(/#DISK_DEVICE_PREFIX#/, disk_device_prefix)
      fstab_data.gsub!(/#FILESYSTEM_TYPE#/, @appliance_config.hardware.partitions['/']['type'])

      fstab = Tempfile.new('fstab')
      fstab << fstab_data
      fstab.flush

      guestfs.upload(fstab.path, "/etc/fstab")

      fstab.close

      @log.debug "'/etc/fstab' file uploaded."
    end

    def install_menu_lst(guestfs)
      @log.debug "Uploading '/boot/grub/menu.lst' file..."
      menu_lst_data = File.open("#{File.dirname(__FILE__)}/src/menu.lst").read

      menu_lst_data.gsub!(/#TITLE#/, @appliance_config.name)
      menu_lst_data.gsub!(/#KERNEL_VERSION#/, @linux_helper.kernel_version(guestfs))
      menu_lst_data.gsub!(/#KERNEL_IMAGE_NAME#/, @linux_helper.kernel_image_name(guestfs))

      menu_lst = Tempfile.new('menu_lst')
      menu_lst << menu_lst_data
      menu_lst.flush

      guestfs.upload(menu_lst.path, "/boot/grub/menu.lst")

      menu_lst.close
      @log.debug "'/boot/grub/menu.lst' file uploaded."
    end

    # This fixes issues with Fedora 14 on EC2: https://bugzilla.redhat.com/show_bug.cgi?id=651861#c39
    def enable_nosegneg_flag(guestfs)
      @log.debug "Enabling nosegneg flag..."
      guestfs.sh("echo \"hwcap 1 nosegneg\" > /etc/ld.so.conf.d/libc6-xen.conf")
      guestfs.sh("/sbin/ldconfig")
      @log.debug "Nosegneg enabled."
    end

    # enable networking on default runlevels
    def enable_networking(guestfs)
      @log.debug "Enabling networking..."
      guestfs.sh("/sbin/chkconfig network on")
      guestfs.upload("#{File.dirname(__FILE__)}/src/ifcfg-eth0", "/etc/sysconfig/network-scripts/ifcfg-eth0")
      @log.debug "Networking enabled."
    end

    def upload_rc_local(guestfs)
      @log.debug "Uploading '/etc/rc.d/rc.local' file..."
      rc_local = Tempfile.new('rc_local')

      if guestfs.exists("/etc/rc.d/rc.local") == 1
        # We're appending
        rc_local << guestfs.read_file("/etc/rc.d/rc.local")
      else
        # We're creating new file
        rc_local << "#!/bin/bash\n\n"
      end

      rc_local << File.read("#{File.dirname(__FILE__)}/src/rc_local")
      rc_local.flush

      guestfs.upload(rc_local.path, "/etc/rc.d/rc.local")

      rc_local.close

      # Fedora 16 doesn't have /etc/rc.local file and we need to
      # enable rc.local compatibility with systemd
      # We need to make sure that network is available when executing rc.local
      if (@appliance_config.os.name == 'fedora' and @appliance_config.os.version >= '16')
        guestfs.cp("/lib/systemd/system/rc-local.service", "/etc/systemd/system/")
        guestfs.sh("sed -i '/^ConditionFileIsExecutable/a After=network.target' /etc/systemd/system/rc-local.service")
        guestfs.sh("systemctl enable rc-local.service")
        guestfs.ln_sf("/etc/rc.d/rc.local", "/etc/rc.local")
        guestfs.chmod(0755, "/etc/rc.d/rc.local")
      end

      @log.debug "'/etc/rc.d/rc.local' file uploaded."
    end

    def change_configuration(guestfs_helper)
      guestfs_helper.augeas do
        # disable password authentication
        set("/etc/ssh/sshd_config", "PasswordAuthentication", "no")

        # disable root login
        set("/etc/ssh/sshd_config", "PermitRootLogin", "without-password")
      end
    end
  end
end

