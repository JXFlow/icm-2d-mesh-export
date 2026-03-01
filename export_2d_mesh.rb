# Export 2D Mesh Generator (Parallel - Bypasses UI Lock)
# ======================================================
# Generates multiple worker scripts + a launcher batch file.
# Each worker runs in a separate IcmExchange.exe process.

require 'date'

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
  
  count = ts_prompt[0].to_i
  puts "User-provided Timestep Count: #{count}"

  if count <= 0
    puts "ERROR: Timestep count must be > 0."
    return
  end

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
  write_merge_script(merge_path, safe_out, worker_files.size, sim_name)
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
  lines << ""
  lines << "begin"
  lines << "  core_idx = #{opts[:core_idx]}"
  lines << "  start_idx = #{opts[:start_idx]}"
  lines << "  end_idx = #{opts[:end_idx]}"
  lines << "  puts \"Worker \#{core_idx}: Starting chunk (\#{start_idx} to \#{end_idx})...\""
  lines << "  puts \"Worker \#{core_idx}: Connecting to database...\""
  lines << "  db = WSApplication.open('#{opts[:safe_db]}', false)"
  lines << "  puts \"Worker \#{core_idx}: Connected!\""
  lines << ""
  lines << "  target = db.model_object('#{opts[:resolved_id]}') rescue nil"
  lines << ""
  lines << "  if target.nil?"
  lines << "    ['Sim', 'Run'].each do |t|"
  lines << "      target = db.model_object_from_type_and_id(t, #{opts[:resolved_id]}) rescue nil"
  lines << "      break if target"
  lines << "    end"
  lines << "  end"
  lines << ""
  lines << "  if target.nil?"
  lines << "    puts \"Worker \#{core_idx}: ERROR - Could not find target!\""
  lines << "    exit(1)"
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
  lines << "  end_idx = [end_idx, total_count - 1].min"
  lines << "  puts \"Worker \#{core_idx}: Processing steps \#{start_idx} to \#{end_idx}\""
  lines << ""
  lines << "  folder = '#{opts[:safe_out]}'"
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
  lines << "  mult_val = #{opts[:mult_str]}.to_f"
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
  lines << "    next if mif_files.empty?"
  lines << "    mif_file = mif_files.first"
  lines << ""
  lines << "    # Parse column map only on the first timestep"
  lines << "    if col_map.nil?"
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
  lines << "      puts \"Worker \#{core_idx}: Columns mapped (Depth=\#{i_depth}, Speed=\#{i_speed})\""
  lines << "    end"
  lines << ""
  lines << "    # Find matching .mid file"
  lines << "    dirname  = File.dirname(mif_file)"
  lines << "    basename = File.basename(mif_file, '.*')"
  lines << "    mid_candidates = [File.join(dirname, \"\#{basename}.mid\"), File.join(dirname, \"\#{basename}.MID\")].select{|f| File.exist?(f)}"
  lines << "    if mid_candidates.empty?"
  lines << "      File.delete(mif_file) rescue nil"
  lines << "      next"
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
  lines << "    File.foreach(mid_file) do |line|"
  lines << "      parts = line.strip.split(',')"
  lines << "      next if parts.size < 4"
  lines << "      id = parts[1]"
  lines << "      dep = (i_depth >= 0) ? parts[i_depth].to_f : 0.0"
  lines << "      s   = (i_speed >= 0) ? parts[i_speed].to_f : 0.0"
  lines << "      dv = dep * s"
  lines << "      d_calc = dv * mult_val"
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
  lines << ""
  lines << "    # Delete immediately (process-and-delete pattern)"
  lines << "    File.delete(mif_file) rescue nil"
  lines << "    File.delete(mid_file) rescue nil"
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
  lines << "  File.write(File.join(folder, \"worker_\#{core_idx}_done.txt\"), 'done')"
  lines << ""
  lines << "rescue => e"
  lines << "  File.write(File.join('#{opts[:safe_out]}', \"worker_\#{core_idx}_error.log\"), e.message + \"\\n\" + e.backtrace.join(\"\\n\"))"
  lines << "  puts \"Worker \#{core_idx}: FATAL ERROR: \#{e.message}\""
  lines << "end"

  File.write(path, lines.join("\n"))
end

# -------------------------------------------------------
# Write the merge script (combines worker CSVs)
# -------------------------------------------------------
def write_merge_script(path, safe_out, num_workers, sim_name)
  lines = []
  lines << "folder = '#{safe_out}'"
  lines << "puts 'Merging worker results...'"
  lines << "global_max = {}"
  lines << ""
  lines << "(0...#{num_workers}).each do |c|"
  lines << "  chunk_file = File.join(folder, \"worker_\#{c}_max.csv\")"
  lines << "  next unless File.exist?(chunk_file)"
  lines << "  headers = true"
  lines << "  File.foreach(chunk_file) do |line|"
  lines << "    if headers; headers = false; next; end"
  lines << "    parts = line.strip.split(',')"
  lines << "    next if parts.size < 8"
  lines << "    id = parts[0]"
  lines << "    dxv = parts[1].to_f; dep = parts[2].to_f; spd = parts[3].to_f"
  lines << "    idx_dxv = parts[4].to_i; idx_dep = parts[5].to_i; idx_spd = parts[6].to_i"
  lines << "    hz = parts[7].to_i"
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
  lines << "  File.delete(chunk_file) rescue nil"
  lines << "  File.delete(File.join(folder, \"worker_c\#{c}.rb\")) rescue nil"
  lines << "  File.delete(File.join(folder, \"worker_\#{c}_done.txt\")) rescue nil"
  lines << "end"
  lines << ""
  lines << "final_csv = File.join(folder, '#{sim_name}_Hazard Mapping.csv')"
  lines << "File.open(final_csv, 'w') do |csv|"
  lines << "  csv.puts 'Element_ID,Max_DxV,Max_Depth,Max_Speed,Step_Index_Max_DxV,Step_Index_Max_Depth,Step_Index_Max_Speed,Max_Hazard_Category'"
  lines << "  global_max.each do |id, v|"
  lines << "    csv.puts \"\#{id},\#{v[0]},\#{v[1]},\#{v[2]},\#{v[3]},\#{v[4]},\#{v[5]},\#{v[6]}\""
  lines << "  end"
  lines << "end"
  lines << "puts \"MERGE COMPLETE -> \#{final_csv}\""

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
  lines << "echo ============================================"
  lines << "echo  Parallel 2D Mesh Export Launcher"
  lines << "echo ============================================"
  lines << "echo."
  lines << "echo Launching #{num_workers} parallel workers..."
  lines << "echo."
  
  worker_files.each_with_index do |wf, i|
    wf_win = wf.gsub('/', '\\')
    lines << "start /MIN \"ICM Worker #{i}\" cmd /c \"\"#{icm_win}\" \"#{wf_win}\" /nogui\""
  end
  
  lines << "echo."
  lines << "echo All #{num_workers} worker windows launched."
  lines << "echo Waiting for all workers to finish..."
  lines << "echo."
  lines << ":POLL_LOOP"
  lines << "timeout /t 5 /nobreak >nul"
  
  # Check if all done files exist
  (0...num_workers).each do |i|
    lines << "if not exist \"#{out_folder}\\worker_#{i}_done.txt\" goto POLL_LOOP"
  end
  
  lines << "echo."
  lines << "echo ============================================"
  lines << "echo  All workers finished! Running merge..."
  lines << "echo ============================================"
  lines << "echo."
  lines << "\"#{icm_win}\" \"#{merge_win}\" /nogui"
  lines << "echo."
  lines << "echo All done!"
  lines << "pause"

  File.write(path, lines.join("\r\n"))
end

generate_export_scripts
