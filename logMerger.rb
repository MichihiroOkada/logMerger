require 'fileutils'
require 'time'
require 'optparse'
require 'pathname'

# ============================================================
# Configuration
# ============================================================
OUTPUT_DIR = 'collected'
TOOLLOG_FILE = 'logMerger.log'
OVERWRITE = true
LOG_ENCODING = 'bom|utf-8'
MERGED_FILENAME = 'merged_logs.log'
SOURCE_FILE_LENGTH = 30

class LogMerger
  def initialize(options)
    @merge      = options[:merge]
    @verbose    = options[:verbose]
    @parse_dir  = options[:dir]
    @isflat     = options[:flat]
    @selected = []

    now = Time.now.strftime('%Y%m%d_%H%M%S')
    @parseroot = File.expand_path(@parse_dir)
    @outputroot = "#{Dir.pwd}\\#{OUTPUT_DIR}_#{now}"
    @toollogfile = File.join(@outputroot, TOOLLOG_FILE)
    @mergedlogfile = File.join(@outputroot, MERGED_FILENAME)

    puts "ROOT_DIR is #{@parseroot}\n"
    puts "OUTPUT_DIR is #{@outputroot}\n"
    abort "エラー: コピー元が存在しません: #{@parseroot}" unless File.directory?(@parseroot)

    begin
      FileUtils.mkdir_p(@outputroot)
    rescue SystemCallError => e
      abort "エラー: コピー先を作成できません: #{e.message}"
    end

    write_log('=== 収集開始 ===')
  end

  # ============================================================
  # ログ出力
  # ============================================================
  def write_log(message, iserror = false)
    if !iserror
      return unless @verbose
    end
    line = "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{message}"
    puts line

    return unless @toollogfile

    begin
      File.open(@toollogfile, 'a:UTF-8') { |f| f.puts(line) }
    rescue SystemCallError, IOError => e
      warn "ログ出力エラー: #{e.message}"
    end
  end

  # ============================================================
  # 時刻フォーマットチェック
  # ============================================================
  def match_for_timestamp(line)
    timestamp_format_list = [
      {
        # YYYY/MM/DD HH:MM:SS
        regexp: /\A(\d{4}\/\d{2}\/\d{2} \d{2}:\d{2}:\d{2})(\s+)(.*)\z/, 
        format: '%Y/%m/%d %H:%M:%S'
      },
      {
        # HH:MM:SS YYYY/MM/DD
        regexp: /\A(\d{2}:\d{2}:\d{2} \d{4}\/\d{2}\/\d{2})(\s+)(.*)\z/, 
        format: '%H:%M:%S %Y/%m/%d'
      }

    ]

    timestamp_text = nil
    timestamp = nil
    timestamp_format_list.each do |timestamp_format|
      if (match = timestamp_format[:regexp].match(line))
          timestamp_text = match[1]
          timestamp = Time.strptime(timestamp_text, timestamp_format[:format])
        return timestamp_text, timestamp, match[2], match[3]
      end
    end

    return timestamp_text, timestamp, nil, nil
  end

  # ============================================================
  # 最新ファイルの選択
  # ============================================================
  def find_latest_files()
    logfiles = {}

    Dir.glob("#{@parseroot}/**/*.log").each do |logfile|
      next if @toollogfile == logfile
      log_dir = File.dirname(logfile)
      log_file = File.basename(logfile)

      if logfiles.has_key?(log_dir) 
        logfiles[log_dir] << log_file 
      else 
        logfiles[log_dir] = []
        logfiles[log_dir] << log_file 
      end
    end

    loggroups = {}
    logfiles.each do |dir, logfiles|
      group = {}
      logfiles.each do |logfile|
        match = logfile.match(/\A([^0-9\.]*)/)
        prefix = match[1]

        if group.has_key?(prefix)
          group[prefix] << logfile
        else
          group[prefix] = []
          group[prefix] << logfile
        end
      end

      loggroups[dir] = group
    end

    loggroups.each do |dir, logfiles|
      logfiles.each do |group, files|
        latestfile = Dir.glob("#{dir}/#{group}*").max_by do |f| File.mtime(f) end
        @selected << latestfile
      end
    end

    write_log("対象ファイル数: #{@selected.size}")
  end

  # ============================================================
  # 最新ファイルのコピー
  # ============================================================
  def copy_latest_files()
    success = 0

    @selected.each do |path|
      logdir = File.dirname(path)
      logfile = File.basename(path)
      relative_dir = "" 

      begin
        relative_dir = Pathname(logdir).relative_path_from(Pathname(@parseroot)) unless @isflat
        FileUtils.mkdir_p("#{@outputroot}/#{relative_dir}") 
        logfullpath = "#{@outputroot}/#{relative_dir}/#{logfile}"

        if File.exist?(logfullpath) && !OVERWRITE
          write_log("[SKIP] コピー先に存在: #{destination}")
          next
        end

        FileUtils.cp(path, logfullpath)
        write_log("[COPY] #{path} -> \n#{logfullpath}")
        success += 1

      rescue SystemCallError, IOError => e
        write_log("[ERROR] コピー失敗: #{path}: #{e.message}", true)
      end
    end

    write_log("コピー成功数: #{success}")
  end

  # ============================================================
  # ログファイルの解析
  # ============================================================
  def parse_log_file(item)
    headers = []
    entries = []
    current = nil
    sequence = 0
    parsed_data = {}

    File.open(item, "r:#{LOG_ENCODING}") do |file|
      file.each_line do |raw_line|
        #line = raw_line.sub(/\r?\n\z/, '')
        line = raw_line.chomp

        timestamp_text, timestamp, spacing, message = match_for_timestamp(line)
        if (timestamp_text)
          sequence += 1

          current = {
            time: timestamp,
            source: File.basename(item),
            sequence: sequence,
            timestamp_text: timestamp_text,
            spacing: spacing,
            message: message,
            continuation: []
          }

          entries << current

        elsif current
          # 時刻なしの行は直前のログの続きとして保持
          current[:continuation] << line

        else
          # 最初の時刻付きログより前はヘッダ
          headers << line
        end
      end
    end

    parsed_data = { 
      source:File.basename(item),
      headers: headers,
      entries: entries
    } 

    return parsed_data
  end

  # ============================================================
  # 時系列マージ
  # ============================================================
  def merge_logs()
    return unless @merge

    parsed_files = []
    all_entries = []

    @selected.each do |item|
      begin
        parsed = parse_log_file(item)
        parsed_files << parsed
        all_entries.concat(parsed[:entries])

        write_log(
          "[PARSE] #{File.basename(item)}: " \
          "#{parsed[:entries].size} 件"
        )

      rescue SystemCallError, IOError, EncodingError,
             ArgumentError => e
        write_log(
          "[ERROR] 読み込み・解析失敗: " \
          "#{File.basename(item)}: #{e.class}: #{e.message}",
          true
        )
      end
    end

    # 時刻、ファイル名、ファイル内の順序でソート
    all_entries.sort_by! do |entry|
      [
        entry[:time],
        entry[:source].downcase,
        entry[:sequence]
      ]
    end

    begin
      File.open(@mergedlogfile, 'w:UTF-8') do |out|
        out.puts '===== FILE HEADERS ====='
        out.puts

        parsed_files.each do |parsed|
          out.puts "----- FILE: #{parsed[:source]} -----"

          if parsed[:headers].empty?
            out.puts '(ヘッダなし)'
          else
            parsed[:headers].each { |line| out.puts line }
          end

          out.puts
        end

        out.puts '===== MERGED LOGS ====='
        out.puts

        all_entries.each do |entry|
          logdata = "#{entry[:timestamp_text]} [#{entry[:source].ljust(SOURCE_FILE_LENGTH)}] #{entry[:spacing]}#{entry[:message]}" 
          out.puts(logdata)
          #out.puts(
          #  "#{entry[:timestamp_text]} " \
          #  "[#{entry[:source]}.ljust(SOURCE_FILE_LENGTH)]" \
          #  "#{entry[:spacing]}#{entry[:message]}"
          #)

          entry[:continuation].each do |line|
            space_text = " "
            out.puts "#{space_text.ljust(entry[:timestamp_text].length)} [#{entry[:source].ljust(SOURCE_FILE_LENGTH)}] #{line}"
          end
        end
      end

      write_log("[MERGE] #{all_entries.size} 件 -> #{@mergedlogfile}")
    rescue SystemCallError, IOError => e
      write_log("[ERROR] マージ結果の保存失敗: #{e.message}", true)
    end
  end

end 


# ============================================================
# メイン処理
# ============================================================
options = { merge: false, verbose: false, flat: false }
OptionParser.new do |opts|
  opts.banner = 'Usage: ruby collect_latest_logs.rb [options]'
  opts.on('--merge', 'コピーに加えて時系列マージを実行') do
    options[:merge] = true
  end
  opts.on('-m', 'コピーに加えて時系列マージを実行') do
    options[:merge] = true
  end
  opts.on('--flat', 'コピー先に階層を持たせないでコピー') do
    options[:flat] = true
  end
  opts.on('-f', 'コピー先に階層を持たせないでコピー') do
    options[:flat] = true
  end
  opts.on('-v', 'ログ出力') do
    options[:verbose] = true
  end
  opts.on('--dir DIR', 'ログディレクトリを指定') do |value|
    options[:dir] = value
  end
end.parse!

logMerger = LogMerger.new(options)

# 最新ログファイルの収集
logMerger.find_latest_files()

# 出力先にコピー
logMerger.copy_latest_files()

# ログのマージ
logMerger.merge_logs()
