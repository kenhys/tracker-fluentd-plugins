require 'open-uri'
require 'json'
require 'logger'
require 'optparse'
require 'yaml'

=begin

Merge script which updates data/checked.json

  Usage: ruby merge-plugins.json

=end

plugins_json_path = File.expand_path(File.join(__dir__, "../data/plugins.json"))
checked_yaml_path = File.expand_path(File.join(__dir__, "../data/checked.yml"))

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
def fetch_or_parse_json(json_path, fetch_url = "")
  unless File.exist?(json_path)
    @logger.info("Fetching <#{json_path}> ...")
    URI.open(fetch_url) do |request|
      File.open(json_path, "w+") { |file| file.write(request.read) }
    end
  end
  File.open(json_path) { |file| JSON.parse(file.read) }
end

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

def custom_yaml_dump(objects)
  buffer = "---\n"
  objects.each do |plugin|
    plugin_name, description = plugin
    buffer <<= <<-EOS
#{plugin_name}: |+
  #{description.strip.split("\n").join("\n  ")}
EOS
  end
  buffer
end

@logger.info("Loading <#{plugins_json_path}> ...")
plugins_url = "https://raw.githubusercontent.com/fluent/fluentd-website/refs/heads/master/scripts/plugins.json"
plugins = fetch_or_parse_json(plugins_json_path, plugins_url)

plugin_names = plugins.collect { |plugin| plugin["name"] }.sort
plugins = plugins.select { |plugin| plugin_names.include?(plugin["name"]) }
@logger.debug("Processing <#{plugins.size}> plugins")

checked = File.open(checked_yaml_path) { |file| YAML.safe_load(file.read) }
known_plugins = checked.keys.sort

n_obsolete = 0
n_src = 0
n_note = 0
n_import = 0
n_update = 0
updated_at = Time.now.strftime("%Y-%m-%d")
plugins.each_with_index do |plugin, index|
  plugin_name = plugin["name"]
  @logger.debug("Processing (#{index+1}/#{plugins.size}) #{plugin_name}")
  unless plugin["note"].nil? or plugin["note"].empty?
    @logger.info("<#{plugin_name}> note: #{plugin['note']}")
    n_note += 1
  end
  if not (plugin["source_code_uri"].nil? or plugin["source_code_uri"].empty?)
    n_src += 1
    @logger.info("<#{plugin_name}> is available from: #{plugin['source_code_uri']}")
  end
  unless plugin["obsolete"].nil?
    @logger.info("<#{plugin_name}> is obsolete")
    n_obsolete += 1
  end
  if known_plugins.include?(plugin_name)
    entry = checked[plugin_name]
    %w(homepage_uri source_code_uri obsolete note).each do |key|
      entry[key] = plugin[key]
    end
    n_update += 1
    @logger.debug("<#{plugin_name}> was updated: #{entry}")
  else
    # Add missing plugins
    entry = plugin.reject { |key, value| %(name info authors version downloads).include?(key) }
    checked[plugin_name] = entry
    n_import += 1
    @logger.debug("<#{plugin_name}> was imported: #{entry}")
  end
  entry["updated_at"] = updated_at
end
File.open("checked.yml", "w+") { |file| file.write(YAML.dump(checked)) }
@logger.warn("<#{checked_yaml_path}> was updated")
message = <<~EOS
obsolete: #{n_obsolete}
note: #{n_note}
source_code_uri: #{n_src}
imported: #{n_import}
updated: #{n_update}
EOS
@logger.info("\nSummary: #{plugins.size} plugins\n#{message}")
