require 'json'
require 'logger'
require 'optparse'
require 'yaml'
require 'fileutils'
require 'timeout'

=begin

Update data/checked.yml manually

  Usage: ruby scripts/update-vcs.rb

=end

options = {
  log_level: Logger::INFO,
  check: %w(vcs ci archived checked_at)
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
opt.on("--check TARGETS", "Specify target fields") { |v| options[:check] = v.split(",") }
opt.parse!(ARGV)

@logger = Logger.new(STDOUT)
@logger.level = options[:log_level]
@logger.formatter = proc { |severity, datetime, progname, message|
  "#{severity}: #{message}\n"
}

checked_yaml_path = File.expand_path(File.join(__dir__, "../data/checked.yml"))
plugins_json_path = File.expand_path(File.join(__dir__, "../data/plugins.json"))

plugins = File.open(plugins_json_path) { |file| JSON.parse(file.read) }
checked = File.open(checked_yaml_path) { |file| YAML.safe_load(file.read) }

plugins.each do |plugin|
  plugin_name = plugin["name"]
  unless checked[plugin_name]
    # import missing plugins
    @logger.warn("<#{plugin_name}> is missing, import it")
    entry = plugin.reject { |key, value| key == "name" }
    if entry["source_code_uri"].nil?
      if entry["homepage_uri"].nil? or entry["homepage_uri"].empty?
        entry["vcs"] = false
      end
    else
      entry["vcs"] = entry["source_code_uri"]
    end
    checked[plugin_name] = entry
  end
  if options[:check].include?("vcs")
    metadata = checked[plugin_name]
    unless metadata["checked_at"]
      unless metadata["vcs"]
        @logger.info("no vcs for <#{plugin_name}>, skip it")
      else
        Dir.chdir("/tmp") do
          wait = false
          begin
            Timeout.timeout(10) do
              `git clone #{metadata["vcs"]} plugin`
            end
            if File.directory?("plugin/.github/workflows")
              metadata["ci"] = "github"
            elsif File.directory?("plugin/.circleci")
              metadata["ci"] = "circleci"
            elsif File.exist?("plugin/.travis.yml")
              metadata["ci"] = "travis"
            else
              metadata["ci"] = false
            end
          rescue Timeout::Error
            @logger.info("Invalid VCS: <#{metadata['vcs']}> for <#{plugin_name}>, skip it")
            metadata["vcs"] = false
            metadata.delete("ci")
          end
          @logger.info("<#{plugin_name}>, #{metadata}")
          metadata["checked_at"] = Time.now.strftime("%Y-%m-%d")
          FileUtils.rm_rf("plugin")
        end
      end
    end
  end
end
checked_yaml_path = "checked.yml"
File.open(checked_yaml_path, "w+") do |file|
  file.write(YAML.dump(checked))
end

