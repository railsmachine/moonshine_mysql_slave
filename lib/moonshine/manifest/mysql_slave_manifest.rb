require "#{File.dirname(__FILE__)}/../../../../moonshine/lib/moonshine.rb"
class MysqlSlaveManifest < Moonshine::Manifest::Rails
  # satisfy Moonshine's requirements for mysql gem, but stub out rails app gems
  configure(:gems => false)

  bind_address = configuration[:mysql][:slaves_bind_address] ||
    Facter.value("ipaddress_#{configuration[:mysql][:slaves_interface] || 'eth1'}".to_sym)
  mysql_extra = configuration[:mysql][:extra] || ''
  configure(:mysql => { :extra => mysql_extra + "\nbind-address = #{bind_address}" })

  # Give each slave a unique server-id
  slaves_interface = configuration[:mysql][:slaves_interface] || 'eth1'
  server_id = nil
  configuration[:mysql][:slaves].each_with_index do |slave, i|
    server_id = i+2 if Facter.value(:fqdn) == slave ||
                       Facter.value(:ipaddress) == slave ||
                       Facter.value("ipaddress_#{slaves_interface}".to_sym) == slave
    break if server_id
  end
  configure(:mysql => { :server_id => server_id })

  recipe :mysql_tools
  recipe :mysql_slave

  # the gem is required for the server recipe, kind of annoying
  recipe :mysql_server, :mysql_gem, :mysql_fixup_debian_start
  recipe :ntp, :time_zone, :postfix, :cron_packages, :motd, :security_updates
  recipe :rails_gems, :rails_directories
end
