# Moonshine MySQL Slaves Plugin

### A plugin for [Moonshine](http://github.com/railsmachine/moonshine)

This plugin assists with installing and managing MySQL slave configuration, as
well as online, non-blocking snapshot back-ups with [XtraBackup](http://www.percona.com/docs/wiki/percona-xtrabackup:start).

### Infrastructure Assumptions

Currently this plugin operates on a few assumptions:

1. The master and all slaves are accessible to Capistrano either publicly or
   through a [gateway](http://weblog.jamisbuck.org/2006/9/26/inside-capistrano-the-gateway-implementation)
   that you have already configured. You may specify IPs or hostnames for the
   slaves.
1. The slaves use a consistent interface for the network over which they
   communicate with the master (e.g. all use eth1). This does not have to match
   the IP/hostname you give for the slave, and it is recommended that you use a
   private network.

If you need a more flexible configuration, patches are welcome :-)

### Instructions

These assume you already have an application in production and are adding a
slave configuration.

- <tt>script/plugin install git://github.com/railsmachine/moonshine_mysql_slave.git</tt>
- <tt>script/plugin install git://github.com/railsmachine/moonshine_mysql_tools.git</tt>
- Configure settings using the <tt>mysql</tt> configuration hash -- you'll need
  to set the IPs or hostnames of your slaves and the interfaces that master and
  slave will use to communicate with one another. The interfaces will be used to
  determine grants and bind-address settings.
```
:mysql:
  :master_interface: eth2 # these default to eth1
  :slaves_interface: eth0
  :slaves:
    - slave1.example.com
    - 10.0.4.3
```
  <em>NOTE: Currently you must configure the slaves array in <tt>moonshine.yml</tt>,
  not via the <tt>configure</tt> method in your manifest. This is the only way
  Moonshine configuration is accessible in Capistrano recipes at this time.</em>
- Edit <tt>database.yml</tt> to set your DB host to the address of the master
  interface, if it is currently set to localhost. Commit this if you're tracking
  the file in revision control.
- Include the plugin and recipe(s) in your Moonshine manifest, *before* the
  <tt>default_stack</tt> recipe is called.
    recipe :mysql_tools
    recipe :mysql_slave
- Add the following callback to your Capistrano config, either in production
  stage config if using multistage, or <tt>deploy.rb</tt> if not.
      after 'moonshine:configure_stage', 'db:set_slave_servers'
  This can't be included in the plugin without it running on all stages all the
  time.
- One more Capistrano hack: change your app's +Capfile+ as follows:
<pre><code>load 'deploy' if respond_to?(:namespace) # cap2 differentiator
Dir['vendor/plugins/*/recipes/*.rb'].sort.each { |plugin| load(plugin) }
load 'config/deploy'
</code></pre>
  With this, Moonshine plugin cap tasks always override Moonshine core's.
- <tt>cap deploy:setup HOSTFILTER=slave1.example.com,10.0.4.3</tt> if not
  already done.
- <tt>cap moonshine_mysql_slave:setup</tt> if the server has already been
  deploy:setup'd.
- <tt>cap db:replication:keys:normalize</tt>
- <tt>cap deploy HOSTFILTER=master.example.com,slave1.example.com,10.0.4.3</tt>
 - This will trigger a MySQL restart if you're changing the bind address for
  the first time.
- <tt>cap db:replication:setup</tt> -- This will momentarily lock tables!

### Security

We *strongly* recommend that you configure a firewall, especially if you have
configured MySQL to listen on a public interface. [moonshine_iptables](http://github.com/railsmachine/moonshine_iptables)
is a great help, for example:
<pre><code>rules = [
  '-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT',
  '-A INPUT -p icmp -j ACCEPT',
  '-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT',
  '-A INPUT -s 127.0.0.1 -j ACCEPT'
]
configuration[:mysql][:slaves].each do |slave|
  rules << "-A INPUT -s #{slave} -p tcp -m tcp --dport 3306 -j ACCEPT"
end
configure(:iptables => { :rules => rules })
plugin :iptables
recipe :iptables
</code></pre>
Note that this example assumes that you're passing an array of internal IPs.
Check out the source of this plugin for a hairier approach to extrapolating from
hostnames.

### Periodic XtraBackup

Optionally, you can set up cron jobs for periodic database backups. XtraBackup
is used for initial slave setup as well, so you must install the mysql_tools
plugin even if you don't wish to configure periodic backups.

Configuration, showing the defaults:
<pre><code>:mysql:
  :xtrabackup:
    :target_dir: /srv/backups/mysql
    :hour_interval: 4
    :retain: 1
    :defaults_file: /etc/mysql/my.cnf
</code></pre>
To use XtraBackup with the default settings:
<pre><code>:mysql:
  :xtrabackup: true
</code></pre>
### Manual Bind Addresses

There are a couple of obscure options available for manually specifying the
bind-address for both master and slave MySQL configs, instead of relying on the
plugin's smarts. These were added primarily for the use case of forcing bind
addresses to 0.0.0.0 (listening on all interfaces), to facilitate migrating to
MySQL Multi-Master. With MMM, the IP address MySQL listens on may change
dynamically, and 0.0.0.0 is the only 'wildcard' mechanism MySQL supports for
this. You generally shouldn't need to do this, and you should be doubly sure
that your iptables configuration is tight if you do!
<pre><code>:mysql:
  :master_bind_address: 0.0.0.0
  :slaves_bind_address: 0.0.0.0
</code></pre>
### TODO

1. Address brittle stuff that has TODO comments.
1. cap tasks for backup restoration and repairing replication.
1. tar4ibd?
1. Look into incremental xtrabackups -- docs are a bit weak.

***
Unless otherwise specified, all content copyright &copy; 2014, [Rails Machine, LLC](http://railsmachine.com)

