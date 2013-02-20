INNOBACKUP = 'innobackupex-1.5.1'

# This callback should be defined in your deploy.rb or only in your production
# multistage config if using multistage. We can't include it in the plugin
# because there is no way to avoid it running on all stages all the time.
#after 'moonshine:configure', 'db:set_slave_servers'

namespace :moonshine do
  desc 'Apply the Moonshine manifest for this application'
  task :apply do
    # Work around stupid cap behavior if, say, you're not defining slaves in
    # your staging environment.
    begin
      apply_db_slaves_manifest
    rescue Capistrano::NoMatchingServersError
      logger.info "skipping MySQL slave Moonshine manifest because no slave servers were defined."
    end
    apply_application_manifest
  end

  task :apply_db_slaves_manifest, :roles => :db, :only => { :slave => true } do
    sudo "RAILS_ROOT=#{latest_release} DEPLOY_STAGE=#{ENV['DEPLOY_STAGE']||fetch(:stage,'undefined')} RAILS_ENV=#{fetch(:rails_env, 'production')} shadow_puppet #{latest_release}/vendor/plugins/moonshine_mysql_slave/lib/moonshine/manifest/mysql_slave_manifest.rb"
  end

  task :apply_application_manifest, :roles => :app do
    sudo "RAILS_ROOT=#{latest_release} DEPLOY_STAGE=#{ENV['DEPLOY_STAGE']||fetch(:stage,'undefined')} RAILS_ENV=#{fetch(:rails_env, 'production')} shadow_puppet #{latest_release}/app/manifests/#{fetch(:moonshine_manifest, 'application_manifest')}.rb"
  end
end

namespace :db do
  desc "[internal] Sets capistrano servers for Moonshine-defined DB slaves"
  task :set_slave_servers do
    if mysql[:slaves]
      mysql[:slaves].each { |slave| server slave, :db, :slave => true }
    end
  end

  namespace :replication do

    desc <<-DESC
      Execute initial 'hot' backup on master DB.
      
      NOTE: this will momentarily read-lock tables to obtain binlog file
      and position at the end of the backup.
    DESC
    task :setup, :roles => :db, :only => { :primary => true } do
      set :xtra_scratch, "/tmp/master-xtrabackup"
      run "mkdir -p #{xtra_scratch}"

      if mysql[:xtrabackup] and mysql[:xtrabackup].is_a?(Hash) and mysql[:xtrabackup][:defaults_file]
        set :mysql_defaults, mysql[:xtrabackup][:defaults_file]
      else
        set :mysql_defaults, '/etc/mysql/my.cnf'
      end

      # We need Net::SSH on master before manifest gets loaded to be applied
      sudo "gem install net-ssh --no-rdoc --no-ri"

      transaction do
        snapshot
        scp
        apply_snapshot
        start_slave
      end
      # PONY: make sure tasks can fix broken replication too :-)
    end

    desc "[internal] Run initial innobackup to snapshot master DB"
    task :snapshot, :roles => :db, :only => { :primary => true } do
      on_rollback { run "rm -rf #{xtra_scratch}/#{latest_backup}" }

      # TODO: instead of parsing output to set these vars, find newest dir
      # in xtra_scratch and read its xtrabackup_binlog_info. That way a separate
      # task can do this so start_slave etc. can be used without a new snapshot
      sudo "#{INNOBACKUP} --defaults-file=#{mysql_defaults} #{xtra_scratch}" do |ch, stream, data|
        logger.info "[#{stream} :: #{ch[:host]}] #{data}"
        if data.match /Backup created in directory \'(.*)\'/
          set :latest_backup, $1.split('/').last
        end
        if data.match /MySQL binlog position: filename \'(.*)\', position (\d*)/
          set :binlog_file, $1
          set :binlog_position, $2
        end
      end
      sudo "chown -R #{user}:#{user} #{xtra_scratch}/#{latest_backup}"
      download_debian_cnf
    end

    desc "[internal] Some obnoxious Debian shit we're going to work around."
    task :download_debian_cnf, :roles => :db, :only => { :primary => true } do
      # http://ubuntuforums.org/showpost.php?p=5192991&postcount=18
      sudo "chown #{user} /etc/mysql/debian.cnf"
      download '/etc/mysql/debian.cnf', 'master_db-debian.cnf'
      sudo "chown root /etc/mysql/debian.cnf"
    end

    desc "[internal] And now for the exciting conclusion to the Debian bullshit"
    task :upload_debian_cnf, :roles => :db, :only => { :slave => true } do
      on_rollback { sudo 'cp /tmp/mysql-debian.cnf /etc/mysql/debian.cnf' }

      sudo 'cp /etc/mysql/debian.cnf /tmp/mysql-debian.cnf'
      sudo "chown #{user} /etc/mysql/debian.cnf"
      upload 'master_db-debian.cnf', '/etc/mysql/debian.cnf'
      sudo 'chown root /etc/mysql/debian.cnf'
    end

    namespace :keys do
      desc "Copy MySQL Master's SSH Keys to Slaves"
      task :normalize do
        master = { :roles => :db, :only => { :primary => true }, :once => true }
        slaves = { :roles => :db, :only => { :slave => true } }

        download "/home/#{user}/.ssh/id_rsa.pub", 'master_db-id_rsa.pub', master
        download "/home/#{user}/.ssh/id_rsa", 'master_db-id_rsa', master
        upload 'master_db-id_rsa', "/home/#{user}/.ssh/id_rsa", slaves
        upload 'master_db-id_rsa.pub', "/home/#{user}/.ssh/id_rsa.pub", slaves

        run "cat /home/#{user}/.ssh/id_rsa.pub >> /home/#{user}/.ssh/authorized_keys", slaves
      end
    end

    desc "[internal] Copy latest innobackupex backup by SCP to slaves."
    task :scp, :roles => :db, :only => { :primary => true } do
      mysql[:slaves].each do |slave|
        run "ssh #{slave} -p #{ssh_options[:port] || 22} 'mkdir -p #{xtra_scratch}'" do |ch, stream, data|
          # pesky SSH fingerprint prompts
          ch.send_data("yes\n") if data =~ %r{\(yes/no\)}
        end
        run "scp -P #{ssh_options[:port] || 22} -r #{xtra_scratch}/#{latest_backup} #{slave}:#{xtra_scratch}"
      end
    end

    desc "[internal] Apply initial XtraBackup snapshot"
    task :apply_snapshot, :roles => :db, :only => { :slave => true } do
      # TODO: do this less dangerously...
      on_rollback do
        sudo 'rm -rf /var/lib/mysql'
        sudo 'mv /var/lib/mysql.old /var/lib/mysql'
        sudo 'service mysql start'
      end

      sudo 'service mysql stop'
      sudo 'rm -rf /var/lib/mysql.old'
      sudo 'mv /var/lib/mysql /var/lib/mysql.old'
      sudo 'mkdir /var/lib/mysql'

      # The whiz-bang part
      sudo "#{INNOBACKUP} --defaults-file=#{mysql_defaults} --apply-log #{xtra_scratch}/#{latest_backup}"
      sudo "#{INNOBACKUP} --defaults-file=#{mysql_defaults} --copy-back #{xtra_scratch}/#{latest_backup}"

      upload_debian_cnf
      sudo 'chown -R mysql:mysql /var/lib/mysql'
      sudo 'service mysql start'
    end

    desc "[internal] Start slave. Depends on :snapshot task to set binlog params"
    task :start_slave, :roles => :db, :only => { :slave => true } do
      # FIXME: this breaks for case like database.production.yml being copied
      # into place later in the deploy
      db_config = YAML.load_file(File.join(File.dirname(__FILE__), '..', '..', '..', '..', 'config', 'database.yml'))
      rails_env = fetch(:rails_env, 'production').to_s
      master_host_query = <<SQL
CHANGE MASTER TO MASTER_HOST='#{db_config[rails_env]['host']}',
MASTER_USER='repl',
MASTER_PASSWORD='#{db_config[rails_env]['password']}',
MASTER_LOG_FILE='#{fetch :binlog_file}',
MASTER_LOG_POS=#{fetch :binlog_position};
SQL

      sudo "/usr/bin/mysql -u root -e \"#{master_host_query}\""
      sudo "/usr/bin/mysql -u root -e 'start slave;'"
      sleep 4   # give it a moment to show us something meaningful
      status
    end

    desc "Check replication with a 'show slave status' query"
    task :status, :roles => :db, :only => { :slave => true } do
      sudo "/usr/bin/mysql -u root -e 'show slave status \\G;'"
    end
  end
end

