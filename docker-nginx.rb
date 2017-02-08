#!/usr/bin/env ruby

require "docker"
require "erb"
require "digest/sha1"
require "ostruct"

class ERBTemplate < OpenStruct
  def render(template)
    ERB.new(File.read(template)).result(binding)
  end
end

class Nginx
  attr_accessor :logger, :config_dir
  def initialize(config_dir:, logger:)
    @config_dir = config_dir
    @logger = logger
  end

  def wait(flags=nil)
    Process.wait(-1, flags)
  rescue Errno::ECHILD
    nil
  end

  def pid
    return @pid if @pid && running?(@pid)
    return unless File.exists?("/run/nginx.pid")
    @pid = File.read("/run/nginx.pid").strip.to_i
  end

  def start!
    return if running?
    Process.spawn("nginx")
    logger.info("Started Nginx, waiting for PID")
    10.times do
      break if running?
      sleep 0.5
    end
    if running?
      logger.info("Started Nginx with pid #{pid}")
    else
      logger.error("Failed to start Nginx.")
    end
  end

  def running?(check_pid=nil)
    check_pid ||= pid
    check_pid && Process.kill(0, check_pid)
  rescue Errno::ESRCH
    false
  end

  def stop!
    Process.kill(:TERM, pid) rescue Errno::ESRCH
  end

  def upgrade!
    return start! unless running?
    Process.kill(:HUP, pid) rescue Errno::ESRCH
  end

  def digest(data)
    Digest::SHA1.hexdigest(data)
  end

  def digest_file(file)
    return unless File.exist?(file)
    digest(File.read(file))
  end

  def config_files
    @config_files ||= begin
      temp_files = Dir.glob(config_dir + "/*erb")
      dst_files = temp_files.map{|t| t.gsub(/.erb$/, "")}
      Hash[temp_files.zip(dst_files)]
    end
  end

  def update!(vars:)
    changed = false
    config_files.each do |template, destination|
      begin
        generated = ERBTemplate.new(vars).render(template)
      rescue Exception => e
        logger.error("Failed to render ERB template from #{template}")
        logger.error(e.inspect)
        e.backtrace.each{|l| logger.error(l)}
        return
      end
      if digest_file(destination) != digest(generated)
        logger.info("Writing updated config #{template} -> #{destination}")
        File.open(destination, "w"){|f| f << generated}
        changed = true
      end
    end
    upgrade! if changed
  end
end

class SigWatcher
  SIGNALS = Signal.list.merge(Signal.list.invert)
  attr_accessor :reader
  def initialize(*signals)
    @reader, @writer = IO.pipe
    signals.each do |sig|
      Signal.trap(sig){@writer.write_nonblock(SIGNALS[sig.to_s])}
    end
  end

  def watch(timeout: nil)
    ready = IO.select([reader], [], [], timeout)
    return unless ready
    msg = ready.first.first.read_nonblock(1.size).to_i
    decode(msg)
  end

  def decode(msg)
    SIGNALS[msg]
  end
end

class Logger
  LEVELS = [:debug, :info, :warning, :error]
  attr_accessor :level
  def initialize(level: :debug)
    @level = level
  end

  def name
    @name ||= File.basename($PROGRAM_NAME, ".rb")
  end

  def should_log?(level)
    LEVELS.index(self.level) <= LEVELS.index(level)
  end

  LEVELS.each do |lev|
    define_method(lev) do |msg|
      puts "[#{name.upcase}] [#{lev.to_s.upcase}] #{msg}" if should_log?(lev)
    end
  end
end

# Monkeypatch in some helper methods to Docker::Image and Docker::Container
module Docker::Base
  def details
    @details ||= json
  end

  def ports
    @ports ||= (details["Config"]["ExposedPorts"] || {}).keys.map{|k| k.split("/").first}
  end

  def env
    return @env if @env
    @env = {}
    details["Config"]["Env"].each do |e|
      key, value = e.split("=", 2)
      case @env[key]
      when String
        @env[key] = [@env[key], value]
      when Array
        @env[key] << value
      else
        @env[key] = value
      end
    end
    @env
  end

  def name
    details["Name"].gsub(/^\//, "") if details["Name"]
  end
end

class Docker::Container
  def image
    @image ||= Docker::Image.get(info["ImageID"])
  rescue
    nil
  end
end

INTERVAL = (ENV["INTERVAL"] || 15).to_i
logger = Logger.new(:level => :info)
nginx = Nginx.new(:config_dir => "/etc/nginx/conf.d", :logger => logger)
sig_watcher = SigWatcher.new(:INT, :QUIT, :TERM, :HUP, :CLD)

$stdout.sync = true
$stderr.sync = true

loop do
  images = {}
  Docker::Container.all.each do |container|
    begin
      image = container.image
      next unless image
    rescue Docker::Error::NotFoundError
      next
    end
    next if image.ports.empty? || container.ports.empty?

    image_name = image.info["RepoTags"].first
    next if image_name.nil?

    # Strip prefix/ and :tag from image name
    key = image_name.match(/^(?:.*\/|)([^:]*)(?::.*|)$/){|m| m[1]}

    images[key] ||= {
      :id => image.id,
      :port => image.ports.first,
      :containers => [],
    }

    images[key][:containers] << {
      :id => container.id,
      :name => container.name,
      :created => container.details["Created"],
      :ipaddr => container.details["NetworkSettings"]["IPAddress"],
      :port => container.ports.first,
    }
  end

  # Sort images by name
  images = Hash[images.to_a.sort_by(&:first)]

  # Sort and add weights to containers
  images.each do |_image_name, image|
    image[:containers].sort_by!{|c| c[:created]}
    image[:containers].first[:weight] = 100
    image[:containers].each{|c| c[:weight] ||= 1}
  end

  nginx.update!(:vars => {:images => images})
  nginx.start!

  if (sig = sig_watcher.watch(:timeout => INTERVAL))
    logger.info("Recieved signal #{sig}")
    case sig.to_sym
    when :INT, :QUIT, :TERM
      logger.info("Shutting down")
      nginx.stop!
      exit
    when :HUP
      logger.info("Forcing update")
      nginx.update!(:vars => {:images => images})
      nginx.upgrade!
    when :CLD
      # Try to reap dead child
      nginx.wait(Process::WNOHANG)
      # Prevent respawn loop
      sleep 1
    end
  end
end
