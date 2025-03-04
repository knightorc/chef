#
# Author:: Seth Chisamore (<schisamo@chef.io>)
# Copyright:: Copyright (c) Chef Software Inc.
# License:: Apache License, Version 2.0
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
#

require_relative "api"
require_relative "api/system"
require "wmi-lite/wmi"

class Chef
  module ReservedNames::Win32
    class Version
      class << self
        include Chef::ReservedNames::Win32::API::System
      end

      include Chef::ReservedNames::Win32::API::Macros
      include Chef::ReservedNames::Win32::API::System

      attr_reader :major_version, :minor_version, :build_number

      # Ruby implementation of
      # http://msdn.microsoft.com/en-us/library/ms724833(v=vs.85).aspx
      # http://msdn.microsoft.com/en-us/library/ms724358(v=vs.85).aspx

      def self.get_system_metrics(n_index)
        GetSystemMetrics(n_index)
      end

      private_class_method :get_system_metrics

      def self.method_name_from_marketing_name(marketing_name)
        "#{marketing_name.gsub(/\s/, "_").tr(".", "_").downcase}?"
      end

      private_class_method :method_name_from_marketing_name

      WIN_VERSIONS = {
        "Windows Server 2022" => { major: 10, minor: 0, callable: lambda { |product_type, suite_mask, build_number| product_type != VER_NT_WORKSTATION && build_number >= 20348 } },
        "Windows Server 2019" => { major: 10, minor: 0, callable: lambda { |product_type, suite_mask, build_number| product_type != VER_NT_WORKSTATION && build_number >= 17763 } },
        "Windows 10" => { major: 10, minor: 0, callable: lambda { |product_type, suite_mask, build_number| product_type == VER_NT_WORKSTATION } },
        "Windows Server 2016" => { major: 10, minor: 0, callable: lambda { |product_type, suite_mask, build_number| product_type != VER_NT_WORKSTATION && build_number <= 14393 } },
        "Windows 8.1" => { major: 6, minor: 3, callable: lambda { |product_type, suite_mask, build_number| product_type == VER_NT_WORKSTATION } },
        "Windows Server 2012 R2" => { major: 6, minor: 3, callable: lambda { |product_type, suite_mask, build_number| product_type != VER_NT_WORKSTATION } },
        "Windows 8" => { major: 6, minor: 2, callable: lambda { |product_type, suite_mask, build_number| product_type == VER_NT_WORKSTATION } },
        "Windows Server 2012" => { major: 6, minor: 2, callable: lambda { |product_type, suite_mask, build_number| product_type != VER_NT_WORKSTATION } },
        "Windows 7" => { major: 6, minor: 1, callable: lambda { |product_type, suite_mask, build_number| product_type == VER_NT_WORKSTATION } },
        "Windows Server 2008 R2" => { major: 6, minor: 1, callable: lambda { |product_type, suite_mask, build_number| product_type != VER_NT_WORKSTATION } },
        "Windows Server 2008" => { major: 6, minor: 0, callable: lambda { |product_type, suite_mask, build_number| product_type != VER_NT_WORKSTATION } },
        "Windows Vista" => { major: 6, minor: 0, callable: lambda { |product_type, suite_mask, build_number| product_type == VER_NT_WORKSTATION } },
        "Windows Server 2003 R2" => { major: 5, minor: 2, callable: lambda { |product_type, suite_mask, build_number| get_system_metrics(SM_SERVERR2) != 0 } },
        "Windows Home Server" => { major: 5, minor: 2, callable: lambda { |product_type, suite_mask, build_number| (suite_mask & VER_SUITE_WH_SERVER) == VER_SUITE_WH_SERVER } },
        "Windows Server 2003" => { major: 5, minor: 2, callable: lambda { |product_type, suite_mask, build_number| get_system_metrics(SM_SERVERR2) == 0 } },
        "Windows XP" => { major: 5, minor: 1 },
        "Windows 2000" => { major: 5, minor: 0 },
      }.freeze

      def initialize
        @major_version, @minor_version, @build_number = get_version
        ver_info = get_version_ex
        @product_type = ver_info[:w_product_type]
        @suite_mask = ver_info[:w_suite_mask]
        @sp_major_version = ver_info[:w_service_pack_major]
        @sp_minor_version = ver_info[:w_service_pack_minor]

        # Obtain sku information for the purpose of identifying
        # datacenter, cluster, and core skus
        @sku = get_product_info(@major_version, @minor_version, @sp_major_version, @sp_minor_version)
      end

      marketing_names = []

      # General Windows checks
      WIN_VERSIONS.each do |k, v|
        method_name = method_name_from_marketing_name(k)
        define_method(method_name) do
          (@major_version == v[:major]) &&
            (@minor_version == v[:minor]) &&
            (v[:callable] ? v[:callable].call(@product_type, @suite_mask, @build_number) : true)
        end
        marketing_names << [k, method_name]
      end

      define_method(:marketing_name) do
        marketing_names.each do |mn|
          break mn[0] if send(mn[1])
        end
      end

      # Server Type checks
      %w{ cluster core datacenter }.each do |m|
        define_method("#{m}?") do
          self.class.constants.any? do |c|
            (self.class.const_get(c) == @sku) &&
              (c.to_s =~ /#{m}/i )
          end
        end
      end

      def win_10_creators_or_higher?
        windows_10? && build_number >= 15063
      end

      private

      def get_version
        # Use WMI here because API's like GetVersion return faked
        # version numbers on Windows Server 2012 R2 and Windows 8.1 --
        # WMI always returns the truth. See article at
        # http://msdn.microsoft.com/en-us/library/windows/desktop/ms724439(v=vs.85).aspx

        wmi = WmiLite::Wmi.new
        os_info = wmi.first_of("Win32_OperatingSystem")
        os_version = os_info["version"]

        # The operating system version is a string in the following form
        # that can be split into components based on the '.' delimiter:
        # MajorVersionNumber.MinorVersionNumber.BuildNumber
        os_version.split(".").collect(&:to_i)
      end

      def get_version_ex
        lp_version_info = OSVERSIONINFOEX.new
        lp_version_info[:dw_os_version_info_size] = OSVERSIONINFOEX.size
        unless GetVersionExW(lp_version_info)
          Chef::ReservedNames::Win32::Error.raise!
        end
        lp_version_info
      end

      def get_product_info(major, minor, sp_major, sp_minor)
        out = FFI::MemoryPointer.new(:uint32)
        GetProductInfo(major, minor, sp_major, sp_minor, out)
        out.get_uint(0)
      end

    end
  end
end
