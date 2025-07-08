require 'json'
require 'logger'
require 'optparse'
require 'yaml'
require 'fileutils'
require 'timeout'
require 'open-uri'

=begin

Update data/obsolete-plugins.yml manually

  Usage: ruby scripts/merge-obsolete-plugins.rb

Read data/checked.yml and write to obsolete-plugins.yml.

=end

options = {
  log_level: Logger::INFO,
  checked: File.expand_path(File.join(__dir__, "../data/checked.yml")),
  obsolete: File.expand_path(File.join(__dir__, "../data/obsolete-plugins.yml")),
  output: "obsolete-plugins.yml",
  strict: false
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
opt.on("--[no-]strict-vcs", "Check with strict rule") { |v| options[:strict] = v }
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

def still_alive?(url)
  begin
    Timeout.timeout(10) do
      URI.open(url)
    end
    return true
  rescue => e
    return false
  end
end

checked.each_with_index do |plugin, index|
  plugin_name, metadata = plugin
  @logger.info("[#{index+1}/#{checked.size}] Checking #{plugin_name}...")
  if metadata["archived"]
    unless obsolete_plugins[plugin_name]
      # already archived, but not listed yet
      message = "Unmaintained since #{metadata['archived_at']}."
      @logger.warn("<#{plugin_name}> was #{message}")
      # Unmaintained since ...
      obsolete_plugins[plugin_name] = message
    end
  elsif metadata["source_code_uri"] and not metadata["source_code_uri"].empty?
    unless obsolete_plugins[plugin_name]
      # check it alive?
      source_code_uri = metadata["source_code_uri"]
      unless still_alive?(source_code_uri)

        # fallback
        homepage_uri = metadata["homepage_uri"]
        if homepage_uri and homepage_uri.empty?
          unless still_alive?(homepage_uri)
            @logger.warn("<#{plugin_name}> homepage URI (#{homepage_uri}) was lost")
            message = "Given homepage URI (#{homepage_uri}) was inaccessible. Only gem is available."
            obsolete_plugins[plugin_name] = message
          end
        else
          # no homepage URI
          @logger.warn("<#{plugin_name}> homepage URI was missing")
          message = "Missing homepage URI. Only gem is available."
          obsolete_plugins[plugin_name] = message
        end
      end
    end
  elsif metadata["homepage_uri"] and not metadata["homepage_uri"].empty?
    unless obsolete_plugins[plugin_name]
      homepage_uri = metadata["homepage_uri"]
      # check it still alive?
      unless still_alive?(homepage_uri)
        @logger.warn("<#{plugin_name}> homepage uri (#{homepage_uri}) was lost")
        message = "Given homepage URI (#{homepage_uri}) was inaccessible. Only gem is available."
        obsolete_plugins[plugin_name] = message
      end
    end
  else
    if options[:strict]
      unless metadata["vcs"]
        unless obsolete_plugins[plugin_name]
          # missing no VCS gem
          if options[:strict]
          else
            @logger.warn("<#{plugin_name}> is missing")
            obsolete_plugins[plugin_name] = "Git repository has gone away."
          end
        end
      end
    end
  end
end
File.open(output_yaml_path, "w+") do |file|
  file.write(custom_yaml_dump(obsolete_plugins))
end

