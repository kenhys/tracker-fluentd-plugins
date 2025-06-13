require 'json'
require 'logger'
require 'optparse'
require 'yaml'
require 'fileutils'
require 'timeout'

=begin

Update data/obsolete-plugins.yml manually

  Usage: ruby scripts/merge-obsolete-plugins.rb

Read data/checked.yml and write to obsolete-plugins.yml.

=end

options = {
  log_level: Logger::INFO,
  checked: File.expand_path(File.join(__dir__, "../data/checked.yml")),
  obsolete: File.expand_path(File.join(__dir__, "../data/obsolete-plugins.yml")),
  output: "obsolete-plugins.yml"
}

opt = OptionParser.new
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
opt.on("--checked CHECKED_YAML", "Specify already manually investigated checked.yml") { |v| options[:checked] = v }
opt.on("--obsolete OBSOLETE_PLUGINS_YAML", "Specify target obsolete-plugins.yml") { |v| options[:obsolete] = v }
opt.on("--output OBSOLETE_PLUGINS_YAML", "Specify target obsolete-plugins.yml") { |v| options[:output] = v }
opt.parse!(ARGV)

@logger = Logger.new(STDOUT)
@logger.level = options[:log_level]
@logger.formatter = proc { |severity, datetime, progname, message|
  "#{severity}: #{message}\n"
}

checked_yaml_path = options[:checked]
obsolete_yaml_path = options[:obsolete]
output_yaml_path = options[:output]

checked = File.open(checked_yaml_path) { |file| YAML.safe_load(file.read) }
if File.exist?(obsolete_yaml_path)
  obsolete_plugins = File.open(obsolete_yaml_path) { |file| YAML.safe_load(file.read) }
else
  obsolete_plugins = {}
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

checked.each do |plugin|
  plugin_name, metadata = plugin
  unless metadata["vcs"]
    unless obsolete_plugins[plugin_name]
      # missing no VCS gem
      @logger.warn("<#{plugin_name}> is missing")
      obsolete_plugins[plugin_name] = "Git repository has gone away."
    end
  end
  if metadata["archived"]
    message = "Unmaintained since #{metadata['archived_at']}."
    unless obsolete_plugins[plugin_name]
      @logger.warn("<#{plugin_name}> was #{message}")
      # Unmaintained since ...
      obsolete_plugins[plugin_name] = message
    else
      obsolete_plugins[plugin_name] << message
    end
  end
end
File.open(output_yaml_path, "w+") do |file|
  file.write(custom_yaml_dump(obsolete_plugins))
end

