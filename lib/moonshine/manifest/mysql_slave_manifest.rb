require "#{File.dirname(__FILE__)}/../../../../moonshine/lib/moonshine.rb"
class MysqlSlaveManifest < Moonshine::Manifest::Rails
  # the gem is required for the server recipe, kind of annoying
  recipe :mysql_server, :mysql_gem, :mysql_fixup_debian_start
  recipe :ntp, :time_zone, :postfix, :cron_packages, :motd, :security_updates

  # satisfy Moonshine's requirements for mysql gem, but stub out rails app gems
  configure(:gems => false)
  recipe :rails_gems

  plugin :mysql_tools
  recipe :mysql_tools
  plugin :mysql_slave
  recipe :mysql_slave
end
