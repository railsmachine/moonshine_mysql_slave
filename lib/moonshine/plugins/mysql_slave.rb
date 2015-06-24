module Moonshine
  module Plugins
    module MysqlSlave

      # Configure this plugin via the <tt>mysql</tt> configuration hash.
      #
      #   configure(:mysql => { :slaves => ['10.0.4.20', '10.0.4.21'] })
      #
      #   plugin :mysql_slave
      #   recipe :mysql_slave
      def mysql_slave(options={})
        options = (configuration[:mysql]||{}).merge(options)

        # Slave-only bits
        if (options[:slaves].include?(Facter.value(:fqdn)) || options[:slaves].include?(Facter.value(:ipaddress)))
          # TODO: only on one slave?
          xtrabackup(options[:xtrabackup]) if options[:xtrabackup]
        else # master
          # Replication grants
          slaves = build_mysql_slave_info(options[:slaves])

          # make the master listen on the internal address
          # TODO: It would be nice to have a bind-interface var in core Moonshine,
          # but adding would force mysql restart when people update -- someday with
          # a major version bump, I guess :-/
          master_interface_address = Facter.value("ipaddress_#{options[:master_interface] || 'eth1'}".to_sym)
          master_bind_address = configuration[:mysql][:master_bind_address] || master_interface_address
          mysql_extra = configuration[:mysql][:extra] || ''
          configure(:mysql => { :extra => mysql_extra + "\nbind-address = #{master_bind_address}" })

          slaves.each do |slave|
            grant = <<EOF
GRANT REPLICATION SLAVE
ON *.*
TO repl@#{slave[:mysql_address]}
IDENTIFIED BY \\"#{database_environment[:password]}\\";
FLUSH PRIVILEGES;
EOF

            exec "#{slave[:mysql_address]}_mysql_repl_user",
              :command => mysql_query(grant),
              :unless  => "mysql -u root -e ' select User from user where Host = \"#{slave[:mysql_address]}\"' mysql | grep repl",
              :require => exec('mysql_database'),
              :before => exec('rake tasks')
          end

          # Moonshine core only grants privs for localhost, so we need
          # to do it for the master's bind-address
          master_grant = <<EOF
GRANT ALL PRIVILEGES
ON #{database_environment[:database]}.*
TO #{database_environment[:username]}@#{master_interface_address}
IDENTIFIED BY \\"#{database_environment[:password]}\\";
FLUSH PRIVILEGES;
EOF

          exec "master_mysql_user",
            :command => mysql_query(master_grant),
            :unless  => "mysqlshow -u#{database_environment[:username]} -p#{database_environment[:password]} -h#{master_interface_address} #{database_environment[:database]}",
            :require => exec('mysql_database'),
            :before  => exec('rake tasks')
        end
      end

    private

      def build_mysql_slave_info(slaves)
        require 'net/ssh'

        slaves.map do |slave|
          # Ugh, we really want iptables to be able to get these IPs easily too
          addr = nil
          begin
            Net::SSH.start(slave, configuration[:user]) do |ssh|
              addr = ssh.exec!(%Q|ruby -rubygems -e "require 'facter'; puts Facter.to_hash['ipaddress_#{options[:slaves_interface] || 'eth1'}']" 2> /dev/null|).strip
            end
          rescue Net::SSH::AuthenticationFailed
            puts "\n\n*** SSH authentication failed. Did you run `cap db:replication:keys:normalize`? ***\n\n"
            raise
          end
          { :host => slave, :mysql_address => addr }
        end

      end

      # The moonshine_mysql_tools plugin installs xtrabackup
      def xtrabackup(options={})
        options = {} if options == true
        target_dir = options[:target_dir] || '/srv/backups/mysql'
        exec 'create xtrabackups dir', :command => "mkdir -p #{target_dir}", :creates => "#{target_dir}"
        file "#{target_dir}",
          :ensure  => :directory,
          :owner   => configuration[:user],
          :group   => configuration[:group] || configuration[:user],
          :require => exec('create xtrabackups dir')

        cron 'xtrabackup-snapshots',
          # Why does this package install only a version-numbered binary? Argh.
          :command => "/usr/bin/innobackupex-1.5.1 --defaults-file=#{options[:defaults_file] || '/etc/mysql/my.cnf'} --stream=tar #{target_dir} | /bin/gzip - > #{target_dir}/xtrabackup_`hostname`_`date '+\\%Y\\%m\\%d-\\%H\\%M\\%S'`.tar.gz 2>> #{configuration[:deploy_to]}/current/log/cron.error.log",
          :hour => "*/#{options[:hour_interval] || 4}",
          :minute => '0'
        cron 'xtrabackup-prune',
          :command => "cd #{target_dir} && rm $(ls -t #{target_dir} | awk 'NR > #{options[:retain] || 2} { print $1 }') >> #{configuration[:deploy_to]}/current/log/cron.log 2>> #{configuration[:deploy_to]}/current/log/cron.error.log",
          :hour => "*/#{options[:hour_interval] || 4}",
          :minute => '8'
      end

    end
  end
end

