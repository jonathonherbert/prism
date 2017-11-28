#!/usr/bin/env ruby

# FIXME: use bundler?
require 'marauder/marauder'
require 'httparty'
require 'net/ssh'
require 'commander/import'
require 'yaml'
require 'tty-prompt'

program :version, Marauder::VERSION
program :description, 'command-line tool to locate infrastructure Y"ALL'

# Load config file
CONFIG_FILE = "#{ENV['HOME']}/.config/marauder/defaults.yaml"

begin
  raise ArgumentError, "Missing configuration file" unless File.exists?(CONFIG_FILE)
  config = YAML.load_file(CONFIG_FILE)
  PRISM_URL = config['prism-url'].gsub(/\/$/,'')
  raise StandardError, "Missing configuration parameter 'prism-url'" unless PRISM_URL && !PRISM_URL.empty?
rescue StandardError, ArgumentError => error
  STDERR.puts "Well that doesn't look right..."
  STDERR.puts "  ... prism-marauder now requires a configuration file which tells it how to connect to Prism"
  STDERR.puts
  STDERR.puts "You need a file at #{CONFIG_FILE} that at a very minimum contains:"
  STDERR.puts "    ---"
  STDERR.puts "    prism-url: http://<prism-host>"
  STDERR.puts
  STDERR.puts "Good luck on your quest"
  raise error
end

class Api
  include HTTParty
  #debug_output $stderr
  disable_rails_query_string_format
end

# If you're sshing into too many hosts, you might be doing something wrong
MAX_SSH_HOSTS = 4

LOGGED_IN_USER = ENV['USER']

def table_rows(rows)
  lengths = rows.map { |row| row.map { |value| value.nil? ? 0 : value.size } }
  col_widths = lengths.transpose.map { |column| column.max }
  rows.map { |row| 
    col_widths.each_with_index.map { |width, index| 
      (row[index] || "").ljust(width)
    }.join("\t")
  }
end

def table(rows)
  table_rows.join("\n")
end

def tokenize(s)
  separators = ['-', '_', '::']
  separators.inject([s]) do |tokens, sep|
    tokens.map {|t| t.split(sep)}.flatten
  end
end

def prism_query(path, filter)
  prism_filters = filter.select{ |f| f =~ /=/ }

  api_query = Hash[prism_filters.map { |f|
    param = f.split('=')
    [param[0], param[1]]
  }.group_by { |pair| 
    pair[0] 
  }.map { |key, kvs| 
    [key, kvs.map{|v| v[1]}]
  }]

  data = Api.get("#{PRISM_URL}#{path}", :query => {:_expand => true}.merge(api_query))

  if data.code != 200
    raise StandardError, "Prism API returned status code #{data.code} in response to #{data.request.last_uri} - check that your configuration file is correct"
  end

  if data["stale"]
    update_time = data["lastUpdated"]
    STDERR.puts "WARNING: Prism reports that the data returned from #{path} is stale, it was last updated at #{update_time}"
  end

  data
end

def token_filter(things_to_filter, filter)
  dumb_filters = filter.reject{ |f| f =~ /=/ }
  query = dumb_filters.map(&:downcase).map{|s| Regexp.new("^#{s}.*")}

  things_to_filter.select do |thing|
    query.all? do |phrase|
      tokens = yield thing
      tokens.compact.any? {|token| phrase.match(token.downcase)}
    end
  end
end

def find_hosts(filter)
  find_instances(filter) + find_hardware(filter)
end

def find_instances(filter)
  data = prism_query('/instances', filter)
  hosts = data["data"]["instances"]
  token_filter(hosts, filter){ |host|
    host["mainclasses"].map{|mc| tokenize(mc)}.flatten + host["mainclasses"] + [host["stage"], host["stack"]] + host["app"]
  }
end

def find_hardware(filter)
  begin
    data = prism_query('/hardware', filter)
    hardware = data["data"]["hardware"]
    token_filter(hardware, filter){ |h| [h["dnsName"], h["stage"], h["stack"]] + h["app"] }
  rescue StandardError => error
    STDERR.puts 'WARNING: The prism server you are using no longer has the hardware endpoint - ignoring request'
    # return an empty list
    []
  end
end

def user_for_host(hostname)
  Net::SSH.configuration_for(hostname)[:user]
end

def get_field_rec(object, fieldList)
  if !object || fieldList.empty?
    object
  else
    get_field_rec(object[fieldList[0]], fieldList.drop(1))
  end
end

def get_field(object, field)
  if field.nil?
    if object['addresses'] && object['addresses']['public'].nil?
      field = 'ip'
    else
      field = 'dnsName'
    end
  end
  get_field_rec(object, field.split('.'))
end

def display_results(matching, options, noun)
  if matching.empty?
      STDERR.puts "No #{noun} found"
  else
    STDERR.puts "#{matching.length} results"
    field_name = options.field || nil
    if options.short
      matching.map { |host| get_field(host, field_name) }.compact.each{ |value| puts value }
    else
      puts table(matching.map { |host|
        app = host['app'].join(',')
        app = host['mainclasses'].join(',') if app.length == 0
        [host['stage'], host['stack'], app, get_field(host, field_name), host['createdAt']]
      })
    end
  end
end

def display_selectah(matching, options, noun)
  if matching.empty?
    STDERR.puts "No #{noun} found"
  else
    STDERR.puts "#{matching.length} results"
    field_name = options.field || nil

    results = matching.map { |host|
      app = host['app'].join(',')
      app = host['mainclasses'].join(',') if app.length == 0
      hostname = get_field(host, field_name)

      [host['stage'], host['stack'], app, hostname, host['createdAt']]
    }

    rows = table_rows(results)
    hostnames = results.map { |result| result[3] }

    results = Hash[rows.zip(hostnames).collect { |result|
      [ result[0], result[1] ]
    }]

    prompt = TTY::Prompt.new

    begin
      result = prompt.select("Choose your destiny", results)
      command = "ssh ubuntu@#{result}"
      system(command)
    rescue TTY::Reader::InputInterrupt
    end
  end
end

###### COMMANDS ######

command :hosts do |c|
  c.description = 'List all hosts (hardware or instances) that match the search filter'
  c.syntax = 'marauder hosts <filter>'
  c.option '-s', '--short', 'Only return hostnames'
  c.option '-f', '--field STRING', String, 'Use specified field from prism'
  c.action do |args, options|
    display_selectah(find_hosts(args), options, 'hosts')
  end
end

command :instances do |c|
  c.description = 'List instances that match the search filter' 
  c.syntax = 'marauder instances <filter>'
  c.option '-s', '--short', 'Only return hostnames'
  c.option '-f', '--field STRING', String, 'Use specified field from prism'
  c.action do |args, options|
    display_selectah(find_instances(args), options, 'instances')
  end
end

command :hardware do |c|
  c.description = 'List hardware that matches the search filter'
  c.syntax = 'marauder hardware <filter>'
  c.option '-s', '--short', 'Only return hostnames'
  c.option '-f', '--field STRING', String, 'Use specified field from prism'
  c.action do |args, options|
    display_selectah(find_hardware(args), options, 'hardware')
  end
end

command :ssh do |c|
  c.syntax = 'marauder ssh <filter>'
  c.description = 'Execute command on matching hosts' 
  c.option '-u', '--user STRING', String, 'Remote username'
  c.option '-c', '--cmd STRING', String, 'Command to execute (quote this if it contains a space)'
  c.action do |args, options|

    STDERR.puts "#{args}"

    query = args.take_while {|s| s != '--'}
    cmd = options.cmd

    STDERR.puts "Query: #{query}"
    STDERR.puts "Command: #{cmd}"

    matching = find_hosts(query)

    if cmd.nil?
      puts "Please provide a command."
      usage
      exit 1
    else if matching.size > MAX_SSH_HOSTS
      exit 1 unless agree("Do you really want to SSH into #{matching.size} hosts?")
    end

    puts "ssh into #{matching.size} hosts and run `#{cmd}`..."
    puts

    matching.each do |host|
      hostname = host['dnsName']
      user = options.user || user_for_host(hostname) || LOGGED_IN_USER
      Net::SSH.start(hostname, user) do |ssh|
        puts "== #{hostname} as #{user} =="
        puts ssh.exec!(cmd)
        puts
        end
      end
    end
  end
end

default_command :instances
