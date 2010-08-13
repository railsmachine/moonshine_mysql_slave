require 'rubygems'
ENV['RAILS_ENV'] = 'test'
ENV['RAILS_ROOT'] ||= File.dirname(__FILE__) + '/../../../..'

$LOAD_PATH.unshift File.join(File.dirname(__FILE__), '..', '..', 'moonshine', 'lib')
$LOAD_PATH.unshift File.join(File.dirname(__FILE__), '..', 'lib')

require 'moonshine'
require 'moonshine/plugins/mysql_slave'
require 'shadow_puppet/test'
require 'net/ssh'

class MysqlSlaveManifest < Moonshine::Manifest::Rails
  path = Pathname.new(__FILE__).dirname.join('..', 'moonshine', 'init.rb')
  Kernel.eval(File.read(path), binding, path)
end
