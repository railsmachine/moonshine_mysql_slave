require File.join(File.dirname(__FILE__), 'spec_helper.rb')

describe "A manifest with the MysqlSlave plugin" do

  before do
    @manifest = MysqlSlaveManifest.new(
      :user => 'rails',
      :mysql => { :slaves => ['slave1.example.com'] }
    )
  end

  it "should be executable" do
    @manifest.should be_executable
  end

  describe "on master" do
    before(:each) do
      mock_master
      @manifest.mysql_slave
    end

    it "should set replication grants for configured slaves" do
      @manifest.execs.keys.should include('10.0.4.3_mysql_repl_user')
    end

    it "should detect and set MySQL bind-address" do
      @manifest.configuration[:mysql][:extra].should match /bind-address = 10.0.4.2/
    end
  end

  describe "on master with a manually configured bind-address" do
    before(:each) do
      @manifest.configure(:mysql => { :master_bind_address => '0.0.0.0' })
      mock_master
      @manifest.mysql_slave
    end

    it "should use the bind-address" do
      @manifest.configuration[:mysql][:extra].should match /bind-address = 0.0.0.0/
    end
  end

  describe "on slave(s)" do
    before(:each) do
      mock_slave
    end

    it "should set up xtrabackup with default options when specified in config" do
      @manifest.mysql_slave :xtrabackup => true
      @manifest.files.keys.should include('/srv/backups/mysql')
      @manifest.crons['xtrabackup-snapshots'][:hour].should match %r{\*/4}
    end

    it "should set up xtrabackup with specified options" do
      @manifest.mysql_slave :xtrabackup => { :target_dir    =>  '/home/backups/mysql',
                                             :hour_interval => 2,
                                             :retain        => 2,
                                             :defaults_file => '/etc/my.cnf' }
      @manifest.files.keys.should include('/home/backups/mysql')
      @manifest.crons['xtrabackup-snapshots'][:hour].should match %r{\*/2}
      @manifest.crons['xtrabackup-prune'][:command].should match /NR > 2/
      @manifest.crons['xtrabackup-snapshots'][:command].should match %r{defaults-file=/etc/my.cnf}
    end
  end

private
  def mock_ssh
    @ssh = mock(Net::SSH)
    Net::SSH.should_receive(:start).with('slave1.example.com', 'rails').and_yield(@ssh)
    @ssh.should_receive(:exec!).and_return('10.0.4.3')  # Slave IP gathering
  end

  def mock_master
    mock_ssh
    Facter.should_receive(:fqdn).and_return('master.example.com')
    Facter.should_receive(:ipaddress_eth1).and_return('10.0.4.2')
  end

  def mock_slave
    Facter.should_receive(:fqdn).and_return('slave1.example.com')
  end
end
