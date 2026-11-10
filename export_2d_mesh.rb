# Export 2D Mesh Generator (Parallel - Bypasses UI Lock)
# ======================================================
# Generates multiple worker scripts + a launcher batch file.
# Each worker runs in a separate IcmExchange.exe process.

require 'date'
require 'tmpdir'

def generate_export_scripts
  puts "=" * 60
  puts "2D Mesh Export - Parallel Batch Script Generator"
  puts "=" * 60

  # Get Database Path
  db_path = ""
  begin
    db = WSApplication.current_database
    db_path = db.path 
  rescue
    db_path = "\\\\localhost\\MASTER_DB" 
  end

  # Prompt 
  prompts_safe = [
    ['Run ID (GUID/Int)', 'String', ''],
    ['Database Path', 'String', db_path],
    ['Output Folder', 'String', 'D:\\Temp', nil, 'FOLDER', 'Select Output Folder'],
    ['Multiplier', 'String', '1.0'],
    ['Keep Timestep CSVs?', 'Boolean', false],
    ['Number of Parallel Workers', 'String', '4'],
    ['IcmExchange.exe Path', 'String', 'C:\\Program Files\\Autodesk\\InfoWorks ICM Ultimate 2026\\IcmExchange.exe']
  ]
  
  res = WSApplication.prompt("Export Options (Parallel)", prompts_safe, false)
  return if res.nil?
  
  run_id     = res[0].strip
  db_path    = res[1].strip
  out_folder = res[2]
  mult_str   = res[3]
  keep_csv   = res[4]
  cores      = res[5].to_i
  icm_exe    = res[6]

  if run_id.empty?
    puts "Error: Run ID required."
    return
  end
  cores = 1 if cores < 1
  
  safe_out = out_folder.gsub('\\', '/')
  safe_db  = db_path.gsub('\\', '/')

  # --- Resolve the target object to get its GUID ---
  puts "Resolving Run ID '#{run_id}' to database GUID..."
  
  target = nil
  begin
    cur_db = WSApplication.current_database
    target = cur_db.model_object(run_id) rescue nil
    
    if target.nil? && run_id.match?(/^\d+$/)
      ['Sim', 'Run'].each do |t|
        target = cur_db.model_object_from_type_and_id(t, run_id.to_i) rescue nil
        if target
          puts "Found via type '#{t}' with numeric ID #{run_id}"
          break
        end
      end
    end
    
    if target.nil?
      cur_db.root_model_objects.each do |r|
        target = _find_recursive(r, run_id)
        break if target
      end
    end
  rescue => e
    puts "Warning during resolve: #{e.message}"
  end

  if target.nil?
    puts "ERROR: Could not resolve Run ID '#{run_id}'. Please check the ID."
    return
  end

  puts "Found Object: #{target.name rescue 'Unknown'} (Type: #{target.type rescue 'Unknown'}, ID: #{target.id})"

  # Navigate to simulation if needed
  if !target.respond_to?(:list_timesteps)
    puts "Object does not have timesteps, looking for Sim child..."
    if target.respond_to?(:children)
      target.children.each do |c|
        puts "  Child: #{c.name rescue '?'} (Type: #{c.type rescue '?'})"
        if c.type == 'Sim'
          target = c
          puts "  -> Selected Simulation: #{target.name}"
          break
        end
      end
    end
  end

  resolved_id = target.id.to_s
  puts "Resolved GUID: #{resolved_id}"
  puts "NOTE: Timestep counting requires IcmExchange. Using user-provided count."

  # Ask user for timestep count (since we can't count them in the UI context)
  ts_prompt = WSApplication.prompt("Enter Total Timestep Count", [
    ['Total Timesteps (from previous run or Check mode)', 'String', '289']
  ], false)
  return if ts_prompt.nil?
  
  count_text = ts_prompt[0].strip
  count = count_text.match?(/\A[0-9]+\z/) ? count_text.to_i : 0
  puts "User-provided Timestep Count: #{count}"

  if count <= 0
    puts "ERROR: Timestep count must be a positive whole number."
    return
  end

  # A fresh directory prevents stale results/status files from satisfying a new run.
  out_folder = Dir.mktmpdir('mesh_export_', out_folder)
  safe_out = out_folder.gsub('\\', '/')

  # --- Chunk the timesteps ---
  chunk_size = (count / cores.to_f).ceil
  
  # --- Generate Worker Scripts ---
  worker_files = []
  
  (0...cores).each do |core_idx|
    start_idx = core_idx * chunk_size
    end_idx = [(start_idx + chunk_size) - 1, count - 1].min
    break if start_idx >= count
    
    rb_name = "worker_c#{core_idx}.rb"
    rb_path = File.join(out_folder, rb_name)
    
    write_worker_script(rb_path, {
      core_idx:    core_idx,
      start_idx:   start_idx,
      end_idx:     end_idx,
      expected_count: count,
      safe_db:     safe_db,
      safe_out:    safe_out,
      resolved_id: resolved_id,
      mult_str:    mult_str,
      keep_csv:    keep_csv
    })
    
    worker_files << rb_path
    puts "Generated: #{rb_path} (Steps #{start_idx}-#{end_idx})"
  end

  sim_name = target.name.to_s.gsub(/[\\\/:*?"<>|]/, '_')  # sanitize for filename
  merge_path = File.join(out_folder, "merge_workers.rb")
  write_merge_script(merge_path, safe_out, worker_files.size, sim_name, count)
  puts "Generated: #{merge_path}"

  # --- Generate Launch Batch File ---
  bat_path = File.join(out_folder, "launch_parallel.bat")
  write_launch_bat(bat_path, icm_exe, worker_files, merge_path)
  puts "Generated: #{bat_path}"

  WSApplication.message_box(
    "Generated #{worker_files.size} worker scripts.\n\nPlease run 'launch_parallel.bat' in:\n#{out_folder}",
    "OK", nil, false
  )
end

# Helper: recursive find
def _find_recursive(parent, id_str)
  return parent if parent.id.to_s == id_str
  if parent.respond_to?(:children)
    parent.children.each do |c|
      found = _find_recursive(c, id_str)
      return found if found
    end
  end
  nil
end

# -------------------------------------------------------
# Write a standalone worker .rb file (NO heredoc nesting)
# -------------------------------------------------------
def write_worker_script(path, opts)
  lines = []
  lines << "require 'date'"
  lines << "require 'fileutils'"
  lines << "require 'csv'"
  lines << ""
  lines << "begin"
  lines << "  core_idx = #{opts[:core_idx]}"
  lines << "  start_idx = #{opts[:start_idx]}"
  lines << "  end_idx = #{opts[:end_idx]}"
  lines << "  puts \"Worker \#{core_idx}: Starting chunk (\#{start_idx} to \#{end_idx})...\""
  lines << "  puts \"Worker \#{core_idx}: Connecting to database...\""
  lines << "  db = WSApplication.open(#{opts[:safe_db].dump}, false)"
  lines << "  puts \"Worker \#{core_idx}: Connected!\""
  lines << ""
  lines << "  target = db.model_object(#{opts[:resolved_id].dump}) rescue nil"
  lines << ""
  lines << "  if target.nil?"
  lines << "    ['Sim', 'Run'].each do |t|"
  lines << "      target = db.model_object_from_type_and_id(t, #{opts[:resolved_id].dump}.to_i) rescue nil"
  lines << "      break if target"
  lines << "    end"
  lines << "  end"
  lines << ""
  lines << "  if target.nil?"
  lines << "    raise 'Could not find target'"
  lines << "  end"
  lines << ""
  lines << "  puts \"Worker \#{core_idx}: Found target: \#{target.name rescue 'Unknown'} (Type: \#{target.type rescue 'Unknown'})\""
  lines << ""
  lines << "  if !target.respond_to?(:list_timesteps)"
  lines << "    if target.respond_to?(:children)"
  lines << "      target.children.each do |c|"
  lines << "        if c.type == 'Sim'"
  lines << "          target = c"
  lines << "          puts \"Worker \#{core_idx}: Navigated to Sim: \#{target.name}\""
  lines << "          break"
  lines << "        end"
  lines << "      end"
  lines << "    end"
  lines << "  end"
  lines << ""
  lines << "  # Verify timesteps exist"
  lines << "  steps = target.list_timesteps"
  lines << "  steps = steps.to_a if steps.respond_to?(:to_a)"
  lines << "  total_count = steps.count"
  lines << "  puts \"Worker \#{core_idx}: Total timesteps in simulation: \#{total_count}\""
  lines << "  raise \"Timestep count mismatch: entered #{opts[:expected_count]}, actual \#{total_count}. Regenerate scripts with the actual count.\" unless total_count == #{opts[:expected_count]} && total_count > 0"
  lines << "  raise 'Invalid timestep range' unless start_idx >= 0 && end_idx >= start_idx && end_idx < total_count"
  lines << "  puts \"Worker \#{core_idx}: Processing steps \#{start_idx} to \#{end_idx}\""
  lines << ""
  lines << "  folder = #{opts[:safe_out].dump}"
  lines << "  temp_folder = File.join(folder, \"temp_calc_\#{core_idx}\")"
  lines << "  Dir.mkdir(temp_folder) unless Dir.exist?(temp_folder)"
  lines << ""
  lines << "  params = {"
  lines << "    'Tables' => ['_2DElements'],"
  lines << "    '2DZoneSQL' => [['Depth', 'depth2d', 4], ['Speed', 'speed2d', 4]],"
  lines << "    'ExportMaxima' => false,"
  lines << "    'AlternativeNaming' => false"
  lines << "  }"
  lines << ""
  lines << "  mult_val = Float(#{opts[:mult_str].dump})"
  lines << "  raise 'Multiplier must be finite' unless mult_val.finite?"
  lines << "  keep_csvs = #{opts[:keep_csv]}"
  lines << "  max_data = {}"
  lines << "  col_map = nil"
  lines << "  i_depth = -1"
  lines << "  i_speed = -1"
  lines << ""
  lines << "  # Iterative Process-and-Delete (safe for disk space)"
  lines << "  (start_idx..end_idx).each do |idx|"
  lines << "    puts \"Worker \#{core_idx}: Step \#{idx}/\#{end_idx}\" if (idx - start_idx) % 10 == 0"
  lines << ""
  lines << "    target.results_GIS_export('MIF', idx, params, temp_folder)"
  lines << ""
  lines << "    mif_files = Dir.glob(File.join(temp_folder, '**', '*.[mM][iI][fF]'))"
  lines << "    raise \"Step \#{idx}: expected one MIF file, found \#{mif_files.size}\" unless mif_files.size == 1"
  lines << "    mif_file = mif_files.first"
  lines << ""
  lines << "    # Validate the column map on every timestep."
  lines << "    begin"
  lines << "      col_map = {}"
  lines << "      col_index = 0"
  lines << "      in_columns = false"
  lines << "      File.foreach(mif_file) do |line|"
  lines << "        line.strip!"
  lines << "        if line.match(/^Columns\\s+(\\d+)/i)"
  lines << "          in_columns = true; next"
  lines << "        end"
  lines << "        if in_columns"
  lines << "          break if line.match(/^Data/i)"
  lines << "          parts = line.split(' ')"
  lines << "          if parts.size >= 2"
  lines << "            col_name = parts[0].gsub('\"', '')"
  lines << "            col_map[col_name] = col_index"
  lines << "            col_index += 1"
  lines << "          end"
  lines << "        end"
  lines << "      end"
  lines << "      i_depth = col_map[col_map.keys.find{|k| k.upcase.include?('DEPTH')}] rescue -1"
  lines << "      i_speed = col_map[col_map.keys.find{|k| k.upcase.include?('SPEED')}] rescue -1"
  lines << "      raise \"Step \#{idx}: missing Depth/Speed columns\" unless i_depth && i_speed && i_depth >= 0 && i_speed >= 0"
  lines << "      puts \"Worker \#{core_idx}: Columns mapped (Depth=\#{i_depth}, Speed=\#{i_speed})\""
  lines << "    end"
  lines << ""
  lines << "    # Find matching .mid file"
  lines << "    dirname  = File.dirname(mif_file)"
  lines << "    basename = File.basename(mif_file, '.*')"
  lines << "    mid_candidates = [File.join(dirname, \"\#{basename}.mid\"), File.join(dirname, \"\#{basename}.MID\")].select{|f| File.exist?(f)}"
  lines << "    if mid_candidates.empty?"
  lines << "      raise \"Step \#{idx}: missing MID file\""
  lines << "    end"
  lines << "    mid_file = mid_candidates.first"
  lines << ""
  lines << "    csv_handle = nil"
  lines << "    if keep_csvs"
  lines << "      step_csv_path = File.join(folder, \"Step_\#{idx}.csv\")"
  lines << "      csv_handle = File.open(step_csv_path, 'w')"
  lines << "      csv_handle.puts 'Element_ID,DxV,Depth,Speed,Hazard_Category'"
  lines << "    end"
  lines << ""
  lines << "    step_ids = {}"
  lines << "    CSV.foreach(mid_file) do |parts|"
  lines << "      raise \"Step \#{idx}: malformed MID row\" unless parts.size == col_map.size && parts[1] && !parts[1].strip.empty?"
  lines << "      id = parts[1]"
  lines << "      raise \"Step \#{idx}: duplicate element \#{id}\" if step_ids[id]"
  lines << "      step_ids[id] = true"
  lines << "      raise \"Step \#{idx}: unexpected element \#{id}\" if idx > start_idx && !max_data.key?(id)"
  lines << "      dep = Float(parts[i_depth]); s = Float(parts[i_speed])"
  lines << "      dv = dep * s"
  lines << "      d_calc = dv * mult_val"
  lines << "      raise \"Step \#{idx}: non-finite result\" unless [dep, s, dv, d_calc].all?(&:finite?)"
  lines << "      hz_cat = 1"
  lines << "      if dep >= 0.01"
  lines << "        if dv > 4.0 || dep > 4.0 || s > 4.0"
  lines << "          hz_cat = 6"
  lines << "        elsif dv > 1.0 || dep > 2.0 || s > 2.0"
  lines << "          hz_cat = 5"
  lines << "        elsif dv > 0.6 || dep > 1.2 || s > 2.0"
  lines << "          hz_cat = 4"
  lines << "        elsif dv > 0.6 || dep > 0.5 || s > 2.0"
  lines << "          hz_cat = 3"
  lines << "        elsif dv > 0.3 || dep > 0.3 || s > 2.0"
  lines << "          hz_cat = 2"
  lines << "        end"
  lines << "      end"
  lines << "      if csv_handle"
  lines << "        id_clean = id.delete('\"').strip"
  lines << "        csv_handle.puts \"\#{id_clean},\#{d_calc},\#{dep},\#{s},\#{hz_cat}\""
  lines << "      end"
  lines << "      if max_data[id].nil?"
  lines << "        max_data[id] = [d_calc, dep, s, idx, idx, idx, hz_cat]"
  lines << "      else"
  lines << "        cur = max_data[id]"
  lines << "        if d_calc > cur[0]; cur[0] = d_calc; cur[3] = idx; end"
  lines << "        if dep > cur[1]; cur[1] = dep; cur[4] = idx; end"
  lines << "        if s > cur[2]; cur[2] = s; cur[5] = idx; end"
  lines << "        if hz_cat > cur[6]; cur[6] = hz_cat; end"
  lines << "        max_data[id] = cur"
  lines << "      end"
  lines << "    end"
  lines << "    csv_handle.close if csv_handle"
  lines << "    raise \"Step \#{idx}: empty or incomplete element results\" if step_ids.empty? || step_ids.size != max_data.size"
  lines << ""
  lines << "    # Delete immediately (process-and-delete pattern)"
  lines << "    File.delete(mif_file)"
  lines << "    File.delete(mid_file)"
  lines << "  end"
  lines << ""
  lines << "  Dir.glob(File.join(temp_folder, '**', '*')).each { |f| File.delete(f) rescue nil }"
  lines << "  Dir.glob(File.join(temp_folder, '**', '*')).select { |d| File.directory?(d) }.each { |d| Dir.rmdir(d) rescue nil }"
  lines << "  Dir.rmdir(temp_folder) rescue nil"
  lines << ""
  lines << "  chunk_csv = File.join(folder, \"worker_\#{core_idx}_max.csv\")"
  lines << "  File.open(chunk_csv, 'w') do |csv|"
  lines << "    csv.puts 'Element_ID,Max_DxV,Max_Depth,Max_Speed,Step_Index_Max_DxV,Step_Index_Max_Depth,Step_Index_Max_Speed,Max_Hazard_Category'"
  lines << "    max_data.each do |id, vals|"
  lines << "      id_clean = id.delete('\"').strip"
  lines << "      csv.puts \"\#{id_clean},\#{vals[0]},\#{vals[1]},\#{vals[2]},\#{vals[3]},\#{vals[4]},\#{vals[5]},\#{vals[6]}\""
  lines << "    end"
  lines << "  end"
  lines << "  puts \"Worker \#{core_idx}: FINISHED! Wrote \#{chunk_csv}\""
  lines << ""
  lines << "  # Write sentinel file so master batch knows we are done"
  lines << "  File.write(File.join(folder, \"worker_\#{core_idx}_done.txt\"), [start_idx, end_idx, total_count, max_data.size].join(','))"
  lines << ""
  lines << "rescue => e"
  lines << "  File.write(File.join(#{opts[:safe_out].dump}, \"worker_\#{core_idx}_error.log\"), e.message + \"\\n\" + e.backtrace.join(\"\\n\"))"
  lines << "  puts \"Worker \#{core_idx}: FATAL ERROR: \#{e.message}\""
  lines << "  exit(1)"
  lines << "end"

  File.write(path, lines.join("\n"))
end

# -------------------------------------------------------
# Write the merge script (combines worker CSVs)
# -------------------------------------------------------
def write_merge_script(path, safe_out, num_workers, sim_name, expected_count)
  lines = []
  lines << "require 'csv'"
  lines << "folder = #{safe_out.dump}"
  lines << "begin"
  lines << "puts 'Merging worker results...'"
  lines << "global_max = {}"
  lines << "next_step = 0"
  lines << "expected_header = 'Element_ID,Max_DxV,Max_Depth,Max_Speed,Step_Index_Max_DxV,Step_Index_Max_Depth,Step_Index_Max_Speed,Max_Hazard_Category'.split(',')"
  lines << ""
  lines << "(0...#{num_workers}).each do |c|"
  lines << "  raise \"Worker \#{c} failed; inspect its error log\" if File.exist?(File.join(folder, \"worker_\#{c}_error.log\"))"
  lines << "  status = File.read(File.join(folder, \"worker_\#{c}_done.txt\")).split(',').map { |v| Integer(v, 10) }"
  lines << "  first, last, total, rows = status"
  lines << "  raise \"Worker \#{c}: invalid completion record\" unless status.size == 4 && first == next_step && last >= first && total == #{expected_count} && last < total && rows > 0"
  lines << "  next_step = last + 1"
  lines << "  chunk_file = File.join(folder, \"worker_\#{c}_max.csv\")"
  lines << "  headers = true"
  lines << "  ids = {}"
  lines << "  CSV.foreach(chunk_file) do |parts|"
  lines << "    if headers"
  lines << "      raise \"Worker \#{c}: invalid CSV header\" unless parts == expected_header"
  lines << "      headers = false; next"
  lines << "    end"
  lines << "    raise \"Worker \#{c}: malformed CSV row\" unless parts.size == 8 && parts[0] && !parts[0].strip.empty?"
  lines << "    id = parts[0]"
  lines << "    raise \"Worker \#{c}: duplicate or unexpected element \#{id}\" if ids[id] || (c > 0 && !global_max.key?(id))"
  lines << "    ids[id] = true"
  lines << "    dxv, dep, spd = parts[1..3].map { |v| Float(v) }"
  lines << "    idx_dxv, idx_dep, idx_spd, hz = parts[4..7].map { |v| Integer(v, 10) }"
  lines << "    raise \"Worker \#{c}: invalid values\" unless [dxv, dep, spd].all?(&:finite?) && [idx_dxv, idx_dep, idx_spd].all? { |v| v >= first && v <= last } && (1..6).include?(hz)"
  lines << "    if global_max[id].nil?"
  lines << "      global_max[id] = [dxv, dep, spd, idx_dxv, idx_dep, idx_spd, hz]"
  lines << "    else"
  lines << "      cur = global_max[id]"
  lines << "      if dxv > cur[0]; cur[0] = dxv; cur[3] = idx_dxv; end"
  lines << "      if dep > cur[1]; cur[1] = dep; cur[4] = idx_dep; end"
  lines << "      if spd > cur[2]; cur[2] = spd; cur[5] = idx_spd; end"
  lines << "      if hz > cur[6]; cur[6] = hz; end"
  lines << "      global_max[id] = cur"
  lines << "    end"
  lines << "  end"
  lines << "  raise \"Worker \#{c}: empty or incomplete CSV\" if headers || ids.size != rows || ids.size != global_max.size"
  lines << "end"
  lines << "raise 'Incomplete timestep coverage' unless next_step == #{expected_count}"
  lines << ""
  lines << "final_csv = File.join(folder, #{(sim_name + '_Hazard Mapping.csv').dump})"
  lines << "File.open(final_csv + '.partial', 'w') do |csv|"
  lines << "  csv.puts 'Element_ID,Max_DxV,Max_Depth,Max_Speed,Step_Index_Max_DxV,Step_Index_Max_Depth,Step_Index_Max_Speed,Max_Hazard_Category'"
  lines << "  global_max.each do |id, v|"
  lines << "    csv.puts \"\#{id},\#{v[0]},\#{v[1]},\#{v[2]},\#{v[3]},\#{v[4]},\#{v[5]},\#{v[6]}\""
  lines << "  end"
  lines << "end"
  lines << "File.rename(final_csv + '.partial', final_csv)"
  lines << "File.write(File.join(folder, 'merge_done.txt'), 'done')"
  lines << "puts \"MERGE COMPLETE -> \#{final_csv}\""
  lines << "rescue => e"
  lines << "  File.write(File.join(folder, 'merge_error.log'), e.message + \"\\n\" + e.backtrace.join(\"\\n\"))"
  lines << "  puts \"MERGE FAILED: \#{e.message}\""
  lines << "  exit(1)"
  lines << "end"

  File.write(path, lines.join("\n"))
end

# -------------------------------------------------------
# Write the launch batch file
# -------------------------------------------------------
def write_launch_bat(path, icm_exe, worker_files, merge_path)
  icm_win = icm_exe.gsub('/', '\\')
  merge_win = merge_path.gsub('/', '\\')
  out_folder = File.dirname(merge_path).gsub('/', '\\')
  num_workers = worker_files.size
  
  lines = []
  lines << "@echo off"
  lines << "setlocal DisableDelayedExpansion"
  lines << 'if not "%~1"=="" goto %~1'
  lines << "if not exist \"#{icm_win}\" goto FAILED"
  lines << "rem Each generated export is single-use; regenerate after a failure."
  lines << "mkdir \"#{out_folder}\\launch_started\" 2>nul"
  lines << "if errorlevel 1 goto FAILED"
  lines << "rem Default worker wait limit: 24 hours (5-second polls)."
  lines << "set max_polls=17280"
  lines << "set polls=0"
  lines << "echo ============================================"
  lines << "echo  Parallel 2D Mesh Export Launcher"
  lines << "echo ============================================"
  lines << "echo."
  lines << "echo Launching #{num_workers} parallel workers..."
  lines << "echo."
  
  worker_files.each_with_index do |wf, i|
    lines << "start /MIN \"ICM Worker #{i}\" cmd /c call \"%~f0\" WORKER_#{i}"
    lines << "if errorlevel 1 goto FAILED"
  end
  
  lines << "echo."
  lines << "echo All #{num_workers} worker windows launched."
  lines << "echo Waiting for all workers to finish..."
  lines << "echo."
  lines << ":POLL_LOOP"
  # Check every error before waiting for any pending worker.
  (0...num_workers).each do |i|
    lines << "if exist \"#{out_folder}\\worker_#{i}_error.log\" goto FAILED"
  end
  (0...num_workers).each do |i|
    lines << "if not exist \"#{out_folder}\\worker_#{i}_exited.txt\" goto WAIT"
  end
  (0...num_workers).each do |i|
    lines << "if not exist \"#{out_folder}\\worker_#{i}_done.txt\" goto FAILED"
  end
  
  lines << "echo."
  lines << "echo ============================================"
  lines << "echo  All workers finished! Running merge..."
  lines << "echo ============================================"
  lines << "echo."
  lines << "\"#{icm_win}\" \"#{merge_win}\" /nogui"
  lines << "if errorlevel 1 goto FAILED"
  lines << "if exist \"#{out_folder}\\merge_error.log\" goto FAILED"
  lines << "if not exist \"#{out_folder}\\merge_done.txt\" goto FAILED"
  lines << "echo."
  lines << "echo All done!"
  lines << "pause"
  lines << "exit /b 0"
  lines << ":WAIT"
  lines << "set /a polls+=1 >nul"
  lines << "if %polls% GEQ %max_polls% goto FAILED"
  lines << "timeout /t 5 /nobreak >nul"
  lines << "goto POLL_LOOP"
  lines << ":FAILED"
  lines << "echo EXPORT FAILED: worker/merge error, missing completion, reused launcher, or wait limit reached."
  lines << "echo Inspect logs in \"#{out_folder}\". Do not use partial results."
  lines << "echo Other workers may still be running. Stop them before removing files; regenerate to retry."
  lines << "pause"
  lines << "exit /b 1"

  # The wrapper detects native crashes/startup failures even if Ruby cannot log them.
  worker_files.each_with_index do |wf, i|
    wf_win = wf.gsub('/', '\\')
    lines << ":WORKER_#{i}"
    lines << "\"#{icm_win}\" \"#{wf_win}\" /nogui >\"#{out_folder}\\worker_#{i}_console.log\" 2>&1"
    lines << "if errorlevel 1 >>\"#{out_folder}\\worker_#{i}_error.log\" echo IcmExchange exited unsuccessfully. See console log."
    lines << "if not exist \"#{out_folder}\\worker_#{i}_done.txt\" >>\"#{out_folder}\\worker_#{i}_error.log\" echo Worker exited without successful completion."
    lines << ">\"#{out_folder}\\worker_#{i}_exited.txt\" echo exited"
    lines << "exit /b 0"
  end

  File.write(path, lines.join("\r\n"))
end

generate_export_scripts if defined?(WSApplication)
