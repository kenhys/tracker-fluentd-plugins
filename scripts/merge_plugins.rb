require 'open-uri'
require 'json'
require 'logger'
require 'optparse'

=begin

Merge script updating data/database.json

  Usage: ruby merge_plugins.json

=end

plugins_json_path = File.expand_path(File.join(__dir__, "../data/plugins.json"))
database_json_path = File.expand_path(File.join(__dir__, "../data/database.json"))

options = {
  log_level: Logger::INFO
}

opt = OptionParser.new
opt.on("--max-gems GEMS", "Specify max processing GEMS") { |v| options[:max_gems] = v.to_i }
opt.on("--log-level LEVEL", "Specify max processing GEMS") { |v|
  case v
  when "info"
    options[:log_level] = Logger::INFO
  when "debug"
    options[:log_level] = Logger::DEBUG
  else
    options[:log_level] = Logger::INFO
  end
}
opt.parse!(ARGV)

@logger = Logger.new(STDOUT)
@logger.level = options[:log_level]
@logger.formatter = proc { |severity, datetime, progname, message|
  "#{severity}: #{message}\n"
}

# Fetch latest plugins.json
@logger.info("Fetching plugins.json ...")
url = "https://raw.githubusercontent.com/fluent/fluentd-website/refs/heads/master/scripts/plugins.json"
URI.open(url) do |request|
  File.open(plugins_json_path, "w+") { |file| file.write(request.read) }
end

@logger.info("Loading #{plugins_json_path} ...")
plugins = File.open(plugins_json_path) { |file| JSON.parse(file.read) }
unless options[:max_gems]
  options[:max_gems] = plugins.size
end

@logger.info("Loading #{database_json_path} ...")
database = if File.exist?(database_json_path)
             File.open(database_json_path) { |file| JSON.parse(file.read) }
           else
             {}
           end

@logger.info("Database files are loaded.")

known_plugins = database.keys
plugin_names = plugins.collect { |plugin| plugin["name"] }.sort[0..(options[:max_gems])]

ARCHIVED_VCS_LIST = %w[
fluent-plugin-aliyun-odps
fluent-plugin-azuremonitorlog
fluent-plugin-kubernetes_sumologic
]

LOST_PLUGIN_VCS_LIST = %w[
fluent-plugin-append-kubernetes-annotations-to-tag
fluent-plugin-archagent
fluent-plugin-aws-sqs
fluent-plugin-bcdb
fluent-plugin-cadvisor
fluent-plugin-cloud-feeds
fluent-plugin-grafana-loki
fluent-plugin-grafana-loki-licence-fix
fluent-plugin-group-exceptions
fluent-plugin-jfrog-metrics
fluent-plugin-jfrog-send-metrics
fluent-plugin-kafka-enchanced
fluent-plugin-logentries
fluent-plugin-multi-exceptions
fluent-plugin-multiline-parser
fluent-plugin-mysql-appender
fluent-plugin-pi
fluent-plugin-redshift
fluent-plugin-seq
fluent-plugin-tail-multiline-ex
]

UNSUPPORTED_VCS_LIST = %w[
fluent-plugin-application-insights-freiheit
]

MANUALLY_CHECKED_VCS_LIST = %w[
fluent-plugin-aliyun-oss
fluent-plugin-aliyun-sls_ruby3
fluent-plugin-amqp-sboagibm
fluent-plugin-amqp2
fluent-plugin-application-insights-freiheit
fluent-plugin-azure-storage-append-blob-lts-azurestack
fluent-plugin-azure-storage-table
fluent-plugin-azure-storage-tables
fluent-plugin-azure-table
fluent-plugin-barito
fluent-plugin-better-timestamp-timekey
fluent-plugin-influxdb-v2
fluent-plugin-jmx
fluent-plugin-json-in-json-2
fluent-plugin-kinesis
fluent-plugin-newrelic
fluent-plugin-prometheus-smarter
fluent-plugin-rabbitmq-typed
fluent-plugin-redis-store-wejick
fluent-plugin-scalyr
fluent-plugin-sentry-rubrik
fluent-plugin-statsd-event
fluent-plugin-statsd-output
fluent-plugin-sumologic_output
fluent-plugin-zabbix-simple-bufferd
]



def suspicious_vcs?(name, url)
  if url.end_with?(".git")
    false
  elsif url.end_with?("/")
    url = url[..-2]
    # detect mismatch about repository name and plugin name
    name != url.split("/").last
  else
    name != url.split("/").last
  end
end

unless ENV["GITHUB_FLUENT_ACCESS_TOKEN"]
  puts "Set GITHUB_FLUENT_ACCESS_TOKEN"
  exit 1
end

@logger.debug("Processing <#{plugins.size}> plugins")
plugins = plugins.select { |plugin| plugin_names.include?(plugin["name"]) }

options[:max_gems].times do |index|
  plugin = plugins.select { |entry| entry["name"] == plugin_names[index] }.first
  @logger.debug("Processing [#{index+1}] #{plugin['name']}")
  if known_plugins.include?(plugin["name"])
    entry = database[plugin["name"]]
    if plugin["homepage_uri"] and plugin["homepage_uri"].start_with?("https://github.com/")
      plugin_name = plugin["name"]
      if LOST_PLUGIN_VCS_LIST.include?(plugin_name)
        entry["vcs"] = false
        database[plugin["name"]] = entry
        @logger.debug("[#{index+1}] LOST #{plugin['name']} #{plugin['homepage_uri']}")
        next
      elsif ARCHIVED_VCS_LIST.include?(plugin_name)
        entry["archived"] = true
        unless entry["vcs"]
          entry["vcs"] = plugin["homepage_uri"]
        end
        @logger.debug("[#{index+1}] ARCHIVED #{plugin['name']} #{plugin['homepage_uri']}")
        database[plugin["name"]] = entry
        next
      elsif MANUALLY_CHECKED_VCS_LIST.include?(plugin_name)
        unless entry["vcs"]
          entry["vcs"] = plugin["homepage_uri"]
          database[plugin["name"]] = entry
        end
        @logger.debug("[#{index+1}] CHECKED #{plugin['name']} #{plugin['homepage_uri']}")
        next
      end
      if suspicious_vcs?(plugin["name"], plugin["homepage_uri"])
        @logger.info("doubt #{plugin['name']} #{entry['vcs']}")
      else
        entry["vcs"] = plugin["homepage_uri"]
      end
    end
    begin
      if entry["vcs"]
        if entry["vcs"].end_with?(".git")
          owner = entry["vcs"].split("/")[-2]
          repo = entry["vcs"].split("/").last.sub(/\.git/, "")
        else
          owner = entry["vcs"].split("/")[-2]
          repo = entry["vcs"].split("/").last
        end
        URI.open("https://api.github.com/repos/#{owner}/#{repo}",
                 "Accept" => "application/vnd.github+json",
                 "Authorization" => "Bearer #{ENV['GITHUB_FLUENT_ACCESS_TOKEN']}",
                 "X-GitHub-Api-Version" => "2022-11-28") do |request|
          JSON.parse(request.read) do |json|
            entry["archived"] = true if json["archived"]
            @logger.info("doubt ARCHIVED #{plugin['name']} repository metadata #{entry['vcs']}")
          end
        end
      end
    rescue => e
      @logger.warn("#{e.message}: doubt #{plugin['name']} repository metadata #{entry['vcs']} is not fetched")
    end
    database[plugin["name"]] = entry
  else
    # Add missing plugins
    entry = {
      "name": plugin["name"],
      "homepage_uri": plugin["homepage_uri"]
    }
    unless plugin["homepage_uri"].nil?
      @logger.debug("check #{plugin['homepage_uri']}")
      if plugin["homepage_uri"].start_with?("https://github.com/")
        entry["vcs"] = plugin["homepage_uri"]
      end
    end
    database[plugin["name"]] = entry
  end
end
File.open(database_json_path, "w+") { |file| file.write(JSON.dump(database)) }
@logger.warn("#{database_json_path} was updated")
